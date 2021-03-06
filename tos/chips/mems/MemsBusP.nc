/*
 * Copyright (c) 2017 Eric B. Decker
 * All rights reserved.
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
 * one instance per MemsBus.
 *
 * mems_id indicates which chip select to use.  Mems_Ids are defined
 * by the platform, like platform_pin_defs.h
 *
 * SpiReg calls are task only (SpiReg vs. SpiRegAsync) and effectively
 * atomic with respect to other MemsBus access.  No arbitration is
 * needed.
 */

generic module MemsBusP() {
  provides interface SpiReg[uint8_t mems_id];
  uses  {
    interface SpiBus;
    interface FastSpiByte;
  }
}
implementation {

#define MEMS_READ_REG   0x80
#define MEMS_AUTO_INC   0x40

  command void SpiReg.read[uint8_t mems_id]
      (uint8_t addr, uint8_t *buf, uint8_t len) {

    nop();
    nop();
    if (len == 0)
      return;
    call SpiBus.set_cs(mems_id);
    addr |= MEMS_READ_REG;              /* set read */
    call FastSpiByte.splitWrite(addr);  /* set reg address */

    /* first byte back is a throw away, and we have least 1 byte */
    call FastSpiByte.splitReadWrite(0);
    while (--len) {                     /* 1st one in flight */
      *buf++ = call FastSpiByte.splitReadWrite(0);
    }
    *buf++ = call FastSpiByte.splitRead();
    call SpiBus.clr_cs(mems_id);
  }


  command void SpiReg.read_multiple[uint8_t mems_id]
      (uint8_t addr, uint8_t *buf, uint8_t len) {
    addr |= MEMS_AUTO_INC;
    call SpiReg.read[mems_id](addr, buf, len);
  }


  command void SpiReg.write[uint8_t mems_id]
      (uint8_t addr, uint8_t *buf, uint8_t len) {

    nop();
    nop();
    if (len == 0)
      return;
    call SpiBus.set_cs(mems_id);
    addr &= 0x7f;                       /* nuke READ bit, just in case */
    call FastSpiByte.splitWrite(addr);  /* set reg address */
    while (len--) {
      call FastSpiByte.splitReadWrite(*buf++);
    }
    call FastSpiByte.splitRead();
    call SpiBus.clr_cs(mems_id);
  }


  command void SpiReg.write_multiple[uint8_t mems_id]
      (uint8_t addr, uint8_t *buf, uint8_t len) {
    addr &= 0x7f;
    addr |= MEMS_AUTO_INC;
    call SpiReg.write[mems_id](addr, buf, len);
  }
}
