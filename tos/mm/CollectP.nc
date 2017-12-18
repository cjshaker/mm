/*
 * CollectP.nc - data collector (record managment) interface
 * between data collection and mass storage.
 *
 * Copyright 2008, 2014, 2017: Eric B. Decker
 * All rights reserved.
 * Mam-Mark Project
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * - Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 *
 * - Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in the
 *   documentation and/or other materials provided with the
 *   distribution.
 *
 * - Neither the name of the copyright holders nor the names of
 *   its contributors may be used to endorse or promote products derived
 *   from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL
 * THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * Collect/RecSum: Record Checksum Implementation
 *
 * Collect records and kick them to Stream Storage.
 *
 * Originally, we provided for data integrity by a single checksum
 * and a sequence number on each sector.  This however, requires
 * a three level implementation to recover split records.
 *
 * Replacing this with a per record checksum results in both the sector
 * checksum and sequence number disappearing.  This greatly simplifies
 * the software implementation and collapses the layers into one.
 *
 * See typed_data.h for details on how the headers are layed out.
 *
 * Mass Storage block size is 512.  If this changes the tag is severly
 * bolloxed as this number is spread a number of different places.  Fucked
 * but true.  Collect uses the entire underlying sector.  This is
 * SD_BLOCKSIZE.  There is no point in abstracting this at the
 * StreamStorage layer.  SD block size permeats too many places.  And it
 * doesn't change.
 *
 * The current implementation has split typed_data headers and data.  A
 * header is required to fit contiguously into a sector and can not be
 * split across a sector boundary.
 *
 * Data associated with a given header however can be split across sector
 * boundaries but is limited to DT_MAX_DLEN.  (defined in typed_data.h).
 *
 * If a header will not fit into the current sector, a DT_TINTRYALF record
 * will be laid down which tells the system to go to the next block.  Dblk
 * headers are kept quad aligned (32 bits alignment) in both memory as well
 * as in the sector buffer and will always be able to fit.  The
 * DT_TINTRYALF dblk is exactly 32 bits long, 2 byte len and 2 byte dtype
 * DT_TINTRYALF.
 *
 * The rationale for only putting whole dblk records into a sector is to
 * optimize access.  Both writing and reading.  The Tag is a highly
 * constrained, very limited resource computing system.  As such we want to
 * make both writing as well as reading to be reasonably efficient and that
 * means minimizing special cases, like when we run off the end of a sector.
 *
 * By organizing how dblk records layout in memory and how they lay out on
 * disk sectors, we should be able to minimize how much additonal overhead
 * is caused by misalignment problems as well as minimize special cases.
 *
 * That's the design philosophy anyway.
 */

#include <typed_data.h>
#include <sd.h>


typedef struct {
  uint16_t     majik_a;
  uint16_t     remaining;
  ss_wr_buf_t *handle;
  uint8_t     *cur_buf;
  uint8_t     *cur_ptr;
  uint16_t     majik_b;
} dc_control_t;

#define DC_MAJIK 0x1008

module CollectP {
  provides {
    interface Collect;
    interface Init;
    interface CollectEvent;
  }
  uses {
    interface SSWrite as SSW;
    interface Panic;
    interface DblkManager;
    interface SysReboot @atleastonce();
    interface LocalTime<TMilli>;
  }
}

implementation {
  norace dc_control_t dcc;

  command error_t Init.init() {
    dcc.majik_a = DC_MAJIK;
    dcc.majik_b = DC_MAJIK;
    return SUCCESS;
  }


  /*
   * finish_sector
   *
   * sector is finished, zero dcc.remaining which will force getting
   * another buffer when we have more bytes to write out.
   *
   * Hand the current buffer off to the writer then reinitialize the
   * control cells to no buffer here.
   */
  void finish_sector() {
    nop();                              /* BRK */
    call SSW.buffer_full(dcc.handle);
    dcc.remaining = 0;
    dcc.handle    = NULL;
    dcc.cur_buf   = NULL;
    dcc.cur_ptr   = NULL;
  }


  void align_next() {
    unsigned int count;
    uint8_t *ptr;

    ptr = dcc.cur_ptr;
    count = (unsigned int) ptr & 0x03;
    if (dcc.remaining == 0 || !count)   /* nothing to align */
      return;
    if (dcc.remaining < 4) {
      finish_sector();
      return;
    }

    /*
     * we know there are at least 5 bytes left
     * chew bytes until aligned.  1, 2, or 3 bytes
     * actually 4 - count at this point.
     *
     * won't change checksum
     */
    switch (count) {
      case 1: *ptr++ = 0;
      case 2: *ptr++ = 0;
      case 3: *ptr++ = 0;
    }
    dcc.cur_ptr = ptr;
    dcc.remaining -= (4 - count);
  }


  /*
   * returns amount actually copied
   */
  static uint16_t copy_block_out(uint8_t *data, uint16_t dlen) {
    uint8_t  *ptr;
    uint16_t num_to_copy;
    unsigned int i;

    num_to_copy = ((dlen < dcc.remaining) ? dlen : dcc.remaining);
    ptr = dcc.cur_ptr;
    for (i = 0; i < num_to_copy; i++)
      *ptr++  = *data++;
    dcc.cur_ptr = ptr;
    dcc.remaining -= num_to_copy;
    return num_to_copy;
  }


  void copy_out(uint8_t *data, uint16_t dlen) {
    uint16_t num_copied;

    if (!data || !dlen)            /* nothing to do? */
      return;
    while (dlen > 0) {
      if (dcc.cur_buf == NULL) {
        /*
         * nobody home, try to go get one.
         *
         * get_free_buf_handle either works or panics.
         */
        dcc.handle = call SSW.get_free_buf_handle();
        dcc.cur_ptr = dcc.cur_buf = call SSW.buf_handle_to_buf(dcc.handle);
        dcc.remaining = SD_BLOCKSIZE;
      }
      num_copied = copy_block_out(data, dlen);
      data += num_copied;
      dlen -= num_copied;
      if (dcc.remaining == 0)
        finish_sector();
    }
  }


  /*
   * All data fields are assumed to be little endian on both sides, tag and
   * host side.
   *
   * header is constrained to be 32 bit aligned (a(4)).  The size of header
   * must be less than DT_MAX_HEADER (+ 1) and data length must be less than
   * DT_MAX_DLEN (+ 1).  Data is immediately copied after the header (its
   * contiguous).
   *
   * hlen is the actual size of the header, dlen is the actual size of the
   * data.  hlen + dlen should match what is laid down in header->len.
   *
   * All dblk headers are assumed to start on a 32 bit boundary (aligned(4)).
   *
   * After writing a header/data combination (the whole typed_data block),
   * we align the next potential typed_data block onto a 32 bit boundary.
   * In other words we always keep typed_data blocks aligned in memory as
   * well as on the disk sector.
   *
   * dblk headers are constrained to fit completely into a data sector.  Data
   * immediately follows the dblk header as long as there is space.  Data
   * can flow into as many sectors as needed following the dblk header.
   */
  command void Collect.collect_nots(dt_header_t *header, uint16_t hlen,
                                    uint8_t     *data,   uint16_t dlen) {
    dt_header_t dt_hdr;
    uint16_t    chksum;
    uint32_t    i;

    if (dcc.majik_a != DC_MAJIK || dcc.majik_b != DC_MAJIK)
      call Panic.panic(PANIC_SS, 1, dcc.majik_a, dcc.majik_b, 0, 0);
    if ((uint32_t) header & 0x3 || (uint32_t) dcc.cur_ptr & 0x03 ||
        dcc.remaining > SD_BLOCKSIZE)
      call Panic.panic(PANIC_SS, 2, (parg_t) header, (parg_t) dcc.cur_ptr, dcc.remaining, 0);
    if (header->len != (hlen + dlen) ||
        header->dtype > DT_MAX       ||
        hlen > DT_MAX_HEADER         ||
        (hlen + dlen) < 4)
      call Panic.panic(PANIC_SS, 3, hlen, dlen, header->len, header->dtype);

    if (dlen > DT_MAX_DLEN)
      call Panic.panic(PANIC_SS, 1, (parg_t) data, dlen, 0, 0);

    header->recnum = call DblkManager.adv_cur_recnum();

    /*
     * our caller is responsible for filling in any pad fields, typically 0.
     *
     * we need to compute the record chksum over all bytes of the header and
     * all bytes of the data area.  Additions to the chksum are done byte by
     * byte.  This has to be done before dumping any of the data and added
     * to the header (recsum).
     */
    chksum = 0;
    header->recsum = 0;
    for (i = 0; i < hlen; i++)
      chksum += ((uint8_t *) header)[i];
    for (i = 0; i < dlen; i++)
      chksum += data[i];
    header->recsum = (uint16_t) (0-chksum);
    nop();                              /* BRK */
    while(1) {
      if (dcc.remaining == 0 || dcc.remaining >= hlen) {
        /*
         * Either no space remains (will grab a new sector/buffer) or the
         * header will fit in what's left.  Just push the header out
         * followed by the data.
         *
         * The header will fit in the SD_BLOCKSIZE bytes in the sector in
         * what is left.  checked for max above.
         */
        copy_out((void *)header, hlen);
        copy_out((void *)data,   dlen);
        align_next();
        return;
      }

      /*
       * there is some space remaining but the header won't fit.  We should
       * always have at least 4 bytes remaining so should be able to laydown
       * the DT_TINTRYALF record (2 bytes len and 2 bytes dtype).
       */
      if (dcc.remaining < 4)
        call Panic.panic(PANIC_SS, 4, dcc.remaining, 0, 0, 0);
      dt_hdr.len = 4;
      dt_hdr.dtype = DT_TINTRYALF;
      copy_out((void *) &dt_hdr, 4);

      /*
       * If we had exactly 4 bytes left, the DT_TINTRYALF will have filled
       * the rest of the buffer resulting in a finish_sector, (no
       * remaining bytes).  But if we still have some remaining then flush
       * the current sector out and start fresh.
       */
      if (dcc.remaining)
        finish_sector();

      /* and try again in the new sector */
    }
  }


  command void Collect.collect(dt_header_t *header, uint16_t hlen,
                               uint8_t     *data,   uint16_t dlen) {
    header->systime = call LocalTime.get();
    call Collect.collect_nots(header, hlen, data, dlen);
  }


  command void CollectEvent.logEvent(uint16_t ev, uint32_t arg0, uint32_t arg1,
                                                  uint32_t arg2, uint32_t arg3) {
    dt_event_t  e;
    dt_event_t *ep;

    ep = &e;
    ep->len = sizeof(e);
    ep->dtype = DT_EVENT;
    ep->ev   = ev;
    ep->arg0 = arg0;
    ep->arg1 = arg1;
    ep->arg2 = arg2;
    ep->arg3 = arg3;
    ep->pcode= 0;
    ep->w    = 0;
    ep->pad  = 0;
    call Collect.collect((void *)ep, sizeof(e), NULL, 0);
  }


  async event void SysReboot.shutdown_flush() {
    dt_sync_t  s;
    dt_sync_t *sp;

    nop();                              /* BRK */

    /*
     * The Stream Writer has been yanked and told to flush any pending
     * buffers.  Most are FULL and SSW will handle those.  But Collect
     * may still have one ALLOC'd..
     *
     * The buffer is ready to go as is.  But if we have room put one last
     * sync record down that records what we currently think current
     * datetime is.  Yeah!
     */
    sp = &s;
    if (dcc.cur_buf) {
      /*
       * have a current buffer.  If we have space then add
       * a SYNC record, which will include a time corellator.
       */
      if (dcc.remaining >= sizeof(dt_sync_t)) {
        sp->len        = sizeof(dt_sync_t);
        sp->dtype      = DT_SYNC;
        sp->systime    = call LocalTime.get();
        sp->sync_majik = SYNC_MAJIK;
        sp->pad0       = sp->pad1       = 0;

        /* fill in datetime */
        copy_block_out((void *) sp, sizeof(dt_sync_t));
      }
      dcc.remaining = 0;
    }
    call SSW.flush_all();
  }

  async event void Panic.hook() { }

}
