/*
 * Copyright (c) 2008, 2010, Eric B. Decker, Carl W. Davis
 * All rights reserved.
 */

#include "panic.h"
#include "typed_data.h"
#include "ms_loc.h"
#include "panic_elem.h"

uint16_t save_sr;
bool save_sr_free;
norace uint8_t _p, _w;
norace uint16_t _a0, _a1, _a2, _a3, _arg;
norace uint32_t last_panic;
norace uint16_t missed_panic_warns;


uint8_t panic_buf[514];
panic_regs_t panic_regs;


#ifdef PANIC_DINT
#define MAYBE_SAVE_SR_AND_DINT	do {	\
    if (save_sr_free) {			\
      save_sr = READ_SR;		\
      save_sr_free = FALSE;		\
    }					\
    dint();				\
} while (0);
#else
#define MAYBE_SAVE_SR_AND_DINT	do {} while (0)
#endif


module PanicP {
  provides {
    interface Panic;
    interface Init;
  }
  uses {
    interface Collect;
    interface LocalTime<TMilli>;
    interface SDsa;
  }
}

implementation {

  struct p_blk_struct {
    bool busy;
    dt_panic_nt blk;
  } p_blk[P_BLK_SIZE];

  

  /*
   * panic_task, send the panic block to the collector
   */

  task void panic_task() {
    int i;

    atomic {
      for (i = 0; i < P_BLK_SIZE; i++) {
	if (p_blk[i].busy) {
	  call Collect.collect((uint8_t *) &p_blk[i].blk, sizeof(dt_panic_nt));
	  p_blk[i].busy = FALSE;
	}
      }
    }
  }


  void debug_break(uint16_t arg)  __attribute__ ((noinline)) {
    _arg = arg;
    nop();
  }


  async command void Panic.warn(uint8_t pcode, uint8_t where, uint16_t arg0, uint16_t arg1,
				uint16_t arg2, uint16_t arg3) {

    struct p_blk_struct *p;

    pcode |= PANIC_WARN_FLAG;

    _p = pcode; _w = where;
    _a0 = arg0; _a1 = arg1;
    _a2 = arg2; _a3 = arg3;

    MAYBE_SAVE_SR_AND_DINT;
    last_panic = call LocalTime.get();
    debug_break(0);

    if (!p_blk[0].busy)
      p = &p_blk[0];

    else if (!p_blk[1].busy)
      p = &p_blk[1];
    else {
      missed_panic_warns++;
      return;
    }

    p->busy = TRUE;
    p->blk.len = sizeof(dt_panic_nt);
    p->blk.dtype = DT_PANIC;
    p->blk.stamp_mis = last_panic;
    p->blk.pcode = pcode;
    p->blk.where = where;
    p->blk.arg0 = arg0;
    p->blk.arg1 = arg1;
    p->blk.arg2 = arg2;
    p->blk.arg3 = arg3;
    post panic_task();
  }


  /*
   * Panic.panic: something really bad happened.
   *
   * Take over the machine and dump state.
   *
   * Panic takes care of the following:
   *
   * . save cpu registers
   * . Find next panic area available from PANIC0
   * . Save the current machine state and header
   * . write out IO area
   * . write out RAM area
   *
   * All SD access uses stand alone routines.
   */

  async command void Panic.panic(uint8_t pcode, uint8_t where, uint16_t arg0, uint16_t arg1,
				 uint16_t arg2, uint16_t arg3) {
    panic0_hdr_t     *p0h;
    panic_elem_hdr_t *pep;
    uint32_t          blk;
    uint8_t          *ram_loc;

    /*
     * Save off the registers first in a temp ram area.
     */
    PANIC_SAVE_REGS16(&panic_regs);

    _p = pcode; _w = where;
    _a0 = arg0; _a1 = arg1;
    _a2 = arg2; _a3 = arg3;
    debug_break(1);

    if (call SDsa.inSA()) {
      debug_break(2);
      while (1)
	nop();
    }

    call SDsa.reset();         // turn on and make ready

    /* find the next panic block location */
    call SDsa.read(PANIC0_SECTOR, panic_buf);
    p0h = (void *) &panic_buf[0];

    /*
     * verify the tombstones and check that nxt is within bounds.
     */
    if (p0h->sig_a != PANIC0_MAJIK            ||
            p0h->panic_nxt < p0h->panic_start ||
            p0h->panic_nxt > p0h->panic_end   ||
	    p0h->panic_nxt == 0) {

      p0h->really_really_fubard_sig = FUBAR_REALLY_REALLY_FUBARD;
      p0h->sig_c = FUBAR_REALLY_REALLY_FUBARD;
      call SDsa.write(PANIC0_SECTOR, panic_buf);
      call SDsa.off();

      /*
       *  What the hell do we do here?
       *
       *  Eric, I think we need a fubartype so we know
       *  what caused the fubar, majik, nxt out of range, etc.
       *  Abort out of here and jump to 0xFFFF
       *  Should/could we force all sensors power down?
       *
       * well for now, let's just bend over and kiss our ass goodbye.
       */
      debug_break(3);
      while (1)
	nop();
    }

    blk = p0h->panic_nxt;
    memset(panic_buf, 0, sizeof(panic_buf));

    pep = (void *) &panic_buf[0];
    pep->panic_majik_a = PANIC0_MAJIK;
    pep->panic_majik_b = PANIC0_MAJIK;
    pep->sys_time = call LocalTime.get();

    /*
     * Save off what happened.
     */
    pep->args.pcode     = pcode;
    pep->args.where     = where;
    pep->args.arg0      = arg0;
    pep->args.arg1      = arg1;
    pep->args.arg2      = arg2;
    pep->args.arg3      = arg3;
    memcpy(&pep->panic_regs, &panic_regs, sizeof(panic_regs_t));

    /*
     * Save state and panic parms
     */  
    call SDsa.write(blk, panic_buf);
    blk++;

    /*
     * i/o space
     *
     * 1 blk
     */

    call SDsa.write(blk, IO_START);
    blk++;

    ram_loc = (void *) RAM_START;
    do {
      call SDsa.write(blk, ram_loc);
      ram_loc += BUF_SIZE;
      blk++;
      debug_break(4);
    } while (ram_loc < (uint8_t *) (RAM_START + RAM_BYTES));

    /*
     * Upate panic next
     */
    call SDsa.read(PANIC0_SECTOR, panic_buf);
    p0h = (void *) &panic_buf[0];
    p0h->panic_nxt = blk;
    call SDsa.write(PANIC0_SECTOR, panic_buf);

    call SDsa.off();
    debug_break(5);
  }


  async command void Panic.brk(uint16_t arg) {
    debug_break(arg);
  }
    

  command error_t Init.init() {
    save_sr_free = TRUE;
    save_sr = 0xffff;
    return SUCCESS;
  }
}
