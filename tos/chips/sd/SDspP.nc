/*
 * SDsp - low level Secure Digital storage driver
 * Split phase, event driven.
 *
 * Copyright (c) 2010, Eric B. Decker, Carl Davis
 * All rights reserved.
 */

#include "msp430hardware.h"
#include "hardware.h"
#include "sd.h"
#include "sd_cmd.h"
#include "panic.h"

/*
 * when resetting.   How long to wait before trying to send the GO_OP
 * to the SD card again.  We let other things happen in the tinyOS system.
 */
#define GO_OP_POLL_TIME 4

#ifdef FAIL
#warning "FAIL defined, undefining, it should be an enum"
#undef FAIL
#endif

#define SD_PUT_GET_TO 1024
#define SD_PARANOID

typedef enum {
  SDS_IDLE = 0,
  SDS_RESET,
  SDS_READ,
  SDS_READ_DMA,
  SDS_WRITE,
  SDS_WRITE_DMA,
  SDS_WRITE_BUSY,
  SDS_ERASE,
} sd_state_t;


module SDspP {
  provides {
    /*
     * SDread, write, and erase are available to clients,
     * SDreset is not parameterized and is intended to only be called
     * by a power manager.
     */
    interface SDreset;
    interface SDread[uint8_t cid];
    interface SDwrite[uint8_t cid];
    interface SDerase[uint8_t cid];
    interface SDsa;			/* standalone */
    interface SDraw;			/* raw */
  }
  uses {
    interface HplMsp430UsciB as Umod;
    interface Hpl_MM_hw as HW;
    interface Panic;
    interface Timer<TMilli> as SDtimer;
    interface LocalTime<TMilli> as lt;
//    interface DmaInterrupt;

//    interface HplMsp430UsciInterrupts as UsciInterrupts;

  }
}

implementation {

#include "platform_sd_spi.h"

  /*
   * main SDsp control cells.   The code can handle at most one operation at a time,
   * duh, we've only got one piece of h/w.
   *
   * SD_Arb provides for arbritration as well as assignment of client ids (cid).
   * SDsp however does not assume access control via the arbiter.  One could wire
   * in directly.  Rather it uses a state variable to control coherent access.  If
   * the driver is IDLE then it allows a client to start something new up.  It is
   * assumed that the client has gained access using the arbiter.  The arbiter is what
   * queuing of clients when the SD is already busy.  When the current client finishes
   * and releases the device, the arbiter will signal the next client to begin.
   *
   * sd_state  current driver state, non-IDLE if we are busy doing something.
   * cur_cid   client id of who has requested the activity.
   * blk_start holds the blk id we are working on
   * blk_end   if needed holds the last block working on (like for erase)
   * data_ptr  buffer pointer if needed.
   *
   * if sd_state is SDS_IDLE these cells are meaningless.
   */

  sd_state_t   sd_state;
  uint8_t      cur_cid;			/* current client */
  uint32_t     blk_start, blk_end;
  uint8_t      *data_ptr;

  uint8_t idle_byte = 0xff;
  uint8_t recv_dump[16];

  sd_cmd_t sd_cmd;


  /* instrumentation
   *
   * need to think about these timeout and how to do with time vs. counts
   */
  uint16_t     sd_r1b_timeout;
  uint16_t     sd_wr_timeout;
  uint16_t     sd_reset_timeout;
  uint16_t     sd_reset_idles;
  uint16_t     sd_go_op_count, sd_read_count;

  uint16_t     sd_read_tok_count;	/* how many times we've looked for a read token */
  uint16_t     tmp_rd_post;
  uint16_t     sd_busy_count;

  uint32_t     max_reset_time_mis, last_reset_time_mis, reset_t0_mis;
  uint16_t     max_reset_time_uis, last_reset_time_uis, reset_t0_uis;

  uint32_t     max_read_time_mis,  last_read_time_mis,  read_t0_mis;
  uint16_t     max_read_time_uis,  last_read_time_uis,  read_t0_uis;

  uint32_t     max_write_time_mis, last_write_time_mis, write_t0_mis;
  uint16_t     max_write_time_uis, last_write_time_uis, write_t0_uis;


  void sd_cmd_crc();


#define sd_panic(where, arg) do { call Panic.panic(PANIC_MS, where, arg, 0, 0, 0); } while (0)
#define  sd_warn(where, arg) do { call  Panic.warn(PANIC_MS, where, arg, 0, 0, 0); } while (0)

  void sd_panic_idle(uint8_t where, uint16_t arg) {
    call Panic.panic(PANIC_MS, where, arg, 0, 0, 0);
    sd_state = SDS_IDLE;
  }


  void sd_chk_clean() {
    uint8_t tmp;

#ifdef SD_PARANOID
    if (SD_SPI_BUSY) {
      sd_panic(16, 0);

      /*
       * how to clean out the transmitter?  It could be
       * hung.  Which would be weird.
       */
    }
    if (SD_SPI_OVERRUN) {
      sd_warn(17, SD_SPI_OE_REG);
      SD_SPI_CLR_OE;
    }
    if (SD_SPI_RX_RDY) {
      tmp = SD_SPI_RX_BUF;
      sd_warn(18, tmp);
    }
#else
    if (SD_SPI_OVERRUN)
      SD_SPI_CLR_OE;
    if (SD_SPI_RX_RDY)
      tmp = SD_SPI_RX_BUF;
#endif
  }


  void sd_put(uint8_t tx_data) {
    uint16_t i;

    SD_SPI_TX_BUF = tx_data;

    i = SD_PUT_GET_TO;
    while ( !(SD_SPI_RX_RDY) && i > 0)
      i--;
    if (i == 0)				/* rx timeout */
      sd_warn(19, 0);
    if (SD_SPI_OVERRUN)
      sd_warn(20, 0);

    tx_data = SD_SPI_RX_BUF;
  }


  uint8_t sg[16];
  uint8_t sg_nxt;

  uint8_t sd_get() {
    uint16_t i;
    uint8_t  byte;

    SD_SPI_TX_BUF = 0xff;

    i = SD_PUT_GET_TO;
    while ( !SD_SPI_RX_RDY && i > 0)
      i--;

    if (i == 0)				/* rx timeout */
      sd_warn(21, 0);

    if (SD_SPI_OVERRUN)
      sd_warn(22, 0);

    byte = SD_SPI_RX_BUF;		/* also clears RXINT */
    sg[sg_nxt++] = byte;
    if (sg_nxt >= 16)
      sg_nxt = 0;
    return byte;
  }


  /*
   * sd_start_dma:  Start up dma 0 and 1 for SD/SPI0 access.
   *
   * input:  sndbuf	pntr to transmit buffer.  If null 0xff will be sent.
   *         rcvbuf	pntr to recveive buffer.  If null no rx bytes will be stored.
   *         length     number of bytes to transfer.   Buffers are assumed to be this size.
   *
   * Channel 0 is used to RX and has priority.  Channel 1 for TX.
   *
   * If sndbuf is NULL, 0xff  will be sent on the transmit side to facilitate receiving.
   * If rcvbuf is NULL, a single byte recv_dump is used to receive incoming bytes.  This
   * is used for transmitting without receiving.
   *
   * To use for clocking the sd: sd_start_dma(NULL, NULL, 10)
   * To use for receiving:       sd_start_dma(NULL, rx_buf, 514)
   * To use for transmitting:    sd_start_dma(tx_buf, NULL, 514)
   *
   * The sector size (block size) is 512 bytes.  The additional two bytes are the crc.
   */

  void sd_start_dma(uint8_t *sndptr, uint8_t *rcvptr, uint16_t length) {
    uint8_t first_byte;

    sd_chk_clean();
    if (length == 0)
      sd_panic(23, length);

    DMA0CTL = 0;			/* hit DMA_EN to disable dma engines */
    DMA1CTL = 0;

    DMA0SA  = (uint16_t) &SD_SPI_RX_BUF;
    DMA0SZ  = length;
    DMA0CTL = DMA_DT_SINGLE | DMA_SB_DB | DMA_DST_NC | DMA_SRC_NC;
    if (rcvptr) {
      /*
       * note we know DMA_DST_NC is 0 so all we need to do is OR
       * in DMA_DST_INC to get the address to increment.
       */
      DMA0DA  = (uint16_t) rcvptr;
      DMA0CTL |= DMA_DST_INC;
    } else
      DMA0DA  = (uint16_t) recv_dump;

    /*
     * There is a race condition that makes using an rx dma engine triggered
     * TSEL_xxRX and the tx engine triggered by TSEL_xxTX when running the
     * UCSI as an SPI.  The race condition causes the rxbuf to get overrun
     * very intermittently.  It loses a byte and the rx dma hangs.  We are
     * looking for the rx dma to complete but one byte got lost.
     *
     * Note this condition is difficult to duplicate.  We've seen it in the main
     * SDspP driver when using TSEL_TX to trigger channel 1.
     *
     * The work around is to trigger both dma channels on the RX trigger.  This
     * only sends a new TX byte after a fresh RX byte has been received and makes
     * sure that there isn't new data coming into the rx serial register which
     * would when complete overwrite the RXBUF causing an over run (and the lost
     * byte).
     *
     * Since the tx channel is triggered by an rx complete, we have to start
     * the transfer up by stuffing the first byte out.  The TXIFG flag is
     * ignored.
     */
    DMA1DA  = (uint16_t) &SD_SPI_TX_BUF;
    DMA1SZ  = length - 1;
    DMA1CTL = DMA_DT_SINGLE | DMA_SB_DB | DMA_DST_NC | DMA_SRC_NC;
    if (sndptr) {
      first_byte = sndptr[0];
      DMA1SA  = (uint16_t) (&sndptr[1]);
      DMA1CTL |= DMA_SRC_INC;
    } else {
      first_byte = 0xff;
      DMA1SA  = (uint16_t) &idle_byte;
    }

    DMACTL0 = DMA0_TSEL_B0RX | DMA1_TSEL_B0RX;

    DMA0CTL |= DMA_EN;			/* must be done after TSELs get set */
    DMA1CTL |= DMA_EN;

    SD_SPI_TX_BUF = first_byte;		/* start dma up */
  }


  /*
   * sd_wait_dma: busy wait for dma to finish.
   *
   * watches channel 0 till DMA_EN goes off.  Channel 0 is RX.
   *
   * Also utilizes the SZ register to find out how many bytes remain
   * and assuming 1uis/byte a reasonable timeout.  A timeout kicks panic.
   */

  void sd_wait_dma() {
    uint16_t max_count, t0;

    t0 = TAR;

    max_count = (DMA1SZ * 8);

    while (DMA0CTL & DMA_EN) {
      if ((TAR - t0) > max_count) {
	sd_panic(24, max_count);
	return;
      }
    }

    DMACTL0 = 0;			/* kick triggers */
    DMA0CTL = DMA1CTL = 0;		/* reset engines 0 and 1 */
  }


  const uint8_t cmd55[] = {
    SD_APP_CMD | 0x40,
    0, 0, 0, 0, 0xff,
  };


  /*
   * ACMDs have to be preceeded by a regular CMD55 to indicate that the next command
   * is from a different command set.
   *
   * CMD55 is a complete op, meaning it does cmd, response, and needs 1 extra byte
   * to finish clocking the SD front end.  We assume CS is already asserted.  We are
   * part of a complete op (ACMD41 for example).
   *
   * This command can be issued while the card is in reset so we ignore the IDLE
   * bit in the response.
   */

  void sd_send_cmd55() {
    uint16_t i;
    uint8_t  rsp, tmp;

    sd_chk_clean();
    sd_start_dma((uint8_t *) cmd55, recv_dump, sizeof(cmd55));
    sd_wait_dma();

    i=0;
    do {
      tmp = sd_get();
      i++;
    } while ((tmp == 0xff) && (i < SD_CMD_TIMEOUT));

    if (i >= SD_CMD_TIMEOUT) {
      sd_panic(25, i);
      return;
    }
    rsp = tmp;
    if (rsp & ~MSK_IDLE)
      sd_panic(26, rsp);
    tmp = sd_get();			/* close the cmd/rsp op */
  }


  /* sd_raw_cmd
   *
   * Send a command to the SD and receive a response from the SD.
   * The response is always a single byte and is the R1 response
   * as documented in the SD manual.
   *
   * raw_cmd does not change the SD card state in any other way
   * meaning it doesn't read any more bytes from the card for other
   * types of responses.
   *
   * Does not provide any kind of transactional control meaning
   * it doesn't send the extra clocks that are needed at the end
   * of a transaction, cmd/rsp, data transfer, etc.
   *
   * return: R1 response byte,  0 says everything is wonderful.
   */

  uint8_t sd_raw_cmd() {
    uint16_t  i;
    uint8_t   tmp, rsp;

    /*
     * We used to check for chip select being down (CSN, low true)
     * but when ACMD processing was pulled out to simplify the code
     * sd_send_acmd now sets CSN and then calls us.  It doesn't hurt
     * anything to really make sure that it is set :-).
     */

    sd_chk_clean();
    sd_start_dma(&sd_cmd.cmd, recv_dump, 6);
    sd_wait_dma();

    /* Wait for a response.  */
    i=0;
    do {
      tmp = sd_get();
      i++;
    } while ((tmp == 0xff) && (i < SD_CMD_TIMEOUT));

    rsp = tmp;				/* response byte */

    /* Just bail if we never got a response */
    if (i >= SD_CMD_TIMEOUT) {
      sd_panic(28, tmp);
      return 0xff;
    }
    return rsp;
  }


  /*
   * send_command:
   *
   * send a simple command to the SD.  A simple command has an R1 response
   * and we handle it as a cmd/rsp transaction with the extra clocks at
   * the end to let the SD finish.
   */
  uint8_t sd_send_command() {
    uint8_t rsp, tmp;

    SD_CSN = 0;
    sd_cmd_crc();
    rsp = sd_raw_cmd();
    tmp = sd_get();			/* close transaction out */
    SD_CSN = 1;
    return rsp;
  }


  /*
   * Send ACMD
   *
   * assume the command in the cmd buffer is an ACMD and should
   * be proceeded by a CMD55.
   *
   * closes the cmd/rsp transaction when done.
   */
  uint8_t sd_send_acmd() {
    uint8_t rsp, tmp;

    SD_CSN = 0;
    sd_send_cmd55();
    rsp = sd_raw_cmd();
    tmp = sd_get();
    SD_CSN = 1;
    return rsp;
  }


  /************************************************************************
   *
   * Reset
   *
   */

  /* Reset the SD card.
   * ret:      0,  card initilized
   * non-zero, error return
   *
   * SPI SD initialization sequence:
   * CMD0 (reset), CMD55 (app cmd), ACMD41 (app_send_op_cond), CMD58 (send ocr)
   */

  command error_t SDreset.reset() {
    sd_cmd_t *cmd;
    uint8_t   rsp;

    if (sd_state) {
      sd_panic_idle(32, sd_state);
      return EBUSY;
    }

    reset_t0_uis = TAR;
    reset_t0_mis = call lt.get();

    sd_state = SDS_RESET;
    cur_cid = -1;			/* reset is not parameterized. */
    cmd = &sd_cmd;

    /* Clock out at least 74 bits of idles (0xFF is 8 bits).  Thats 10 bytes. This allows
     * the SD card to complete its power up prior to us talking to
     * the card.
     */

    SD_CSN = 1;				/* force to known state */
    sd_start_dma(NULL, recv_dump, 10);	/* send 10 0xff to clock SD */
    sd_wait_dma();

    /* Put the card in the idle state, non-zero return -> error */
    cmd->cmd = SD_FORCE_IDLE;		// Send CMD0, software reset
    cmd->arg = 0;
    rsp = sd_send_command();
    if (rsp & ~MSK_IDLE) {		/* ignore idle for errors */
      sd_panic_idle(33, rsp);
      return FAIL;
    }

    /*
     * force the timer to go, which sends the first go_op.
     * eventually it will cause a resetDone to get sent.
     *
     * This switches us to the context that we want so the
     * signal for resetDone always comes from the same place.
     */
    sd_go_op_count = 0;		// Reset our counter for pending tries
    call SDtimer.startOneShot(0);
    return SUCCESS;
  }


  event void SDtimer.fired() {
    sd_cmd_t *cmd;
    uint8_t   rsp;

    switch (sd_state) {
      default:
	return;

      case SDS_RESET:
	cmd = &sd_cmd;
	cmd->cmd = SD_GO_OP;            // Send ACMD41
	rsp = sd_send_acmd();
	if (rsp & ~MSK_IDLE) {		/* any other bits set? */
	  sd_panic_idle(37, rsp);
	  signal SDreset.resetDone(FAIL);
	  return;
	}

	if (rsp & MSK_IDLE) {
	  /* idle bit still set, means card is still in reset */
	  if (++sd_go_op_count >= SD_GO_OP_MAX) {
	    sd_panic_idle(38, sd_go_op_count);			// We maxed the tries, panic and fail
	    signal SDreset.resetDone(FAIL);
	    return;
	  }
	  call SDtimer.startOneShot(GO_OP_POLL_TIME);
	  return;
	}

	/*
	 * no longer idle, initialization was OK.
	 *
	 * If we were running with a reduced clock then this is the place to
	 * crank it up to full speed.  We do everything at full speed so there
	 * isn't currently any need.
	 */

	last_reset_time_uis = TAR - reset_t0_uis;
	if (last_reset_time_uis > max_reset_time_uis)
	  max_reset_time_uis = last_reset_time_uis;

	last_reset_time_mis = call lt.get() - reset_t0_mis;
	if (last_reset_time_mis > max_reset_time_mis)
	  max_reset_time_mis = last_reset_time_mis;

	nop();
	sd_state = SDS_IDLE;
	signal SDreset.resetDone(SUCCESS);
	return;
    }
  }


  /*
   * sd_check_crc
   *
   * i: data	pointer to a 512 byte + 2 bytes of CRC at end (512, 513)
   *
   * o: rtn	0 (SUCCESS) if crc is okay
   *		1 (FAIL) crc didn't check.
   *
   * SD_BLOCKSIZE is the size of the buffer (includes crc at the end)
   */

  int sd_check_crc(uint8_t *data, uint16_t crc) {
    return SUCCESS;
  }


  /* sd_compute_crc
   *
   * append a crc computed over the data buffer pointed at by data
   *
   * i: data	ptr to 512 bytes of data (with 2 additional bytes available
   *		at the end for the crc (total size 514).
   * o: none
   */

  void sd_compute_crc(uint8_t *data) {
    data[512] = 0;
    data[513] = 0;
  }


  /*
   * sd_cmd_crc
   *
   * set the crc for the command block
   *
   * currently we just force 0x95 which is the crc for GO_IDLE
   */

  void sd_cmd_crc() {
    sd_cmd.crc = 0x95;
  }


  uint16_t sd_read_status() {
    uint8_t  tmp, rsp, stat_byte;

    SD_CSN = 0;
    rsp = sd_raw_cmd();
    stat_byte = sd_get();
    tmp = sd_get();			/* close it off */
    SD_CSN = 1;
    return ((rsp << 8) | stat_byte);
  }


  /************************************************************************
   *
   * Read
   *
   */

  task void sd_read_task() {
    uint8_t tmp;

    /* Wait for the token */
    sd_read_tok_count++;
    tmp = sd_get();			/* read a byte from the SD */

    if ((tmp & MSK_TOK_DATAERROR) == 0 || sd_read_tok_count >= SD_READ_TOK_MAX) {
      /* Clock out a byte before returning, let SD finish */
      sd_get();

      /* The card returned an error, or timed out. */
      call Panic.panic(PANIC_MS, 39, tmp, sd_read_tok_count, 0, 0);
      sd_state = SDS_IDLE;
      signal SDread.readDone[cur_cid](blk_start, data_ptr, FAIL);
      return;
    }

    /*
     * if we haven't seen the token yet then try again.  We just repost
     * ourselves to try again.  This lets others run.  We've observed
     * that in a tight loop it took about 50-60 loops before we saw the token
     * about 300 uis.  Not enough to kick a timer off (mis granularity) but
     * long enough that we don't want to sit on the cpu.
     */
    if (tmp == 0xFF) {			/* should we explicitly check for START_TOK? */
      post sd_read_task();
      return;
    }

    /* read the block (512 bytes) and include the crc (2 bytes) */
    sd_state = SDS_READ_DMA;
    sd_start_dma(NULL, data_ptr, SD_BUF_SIZE);
    DMA0_ENABLE_INT;
    return;
  }


  void sd_read_dma_handler() {
    uint16_t crc;

    DMACTL0 = 0;			/* kick triggers */
    DMA0CTL = DMA1CTL = 0;		/* reset engines 0 and 1 */

    SD_CSN = 1;				/* deassert CS */

    /* Send some extra clocks so the card can finish */
    sd_put(0xff);
    sd_put(0xff);

    crc = (data_ptr[512] << 8) | data_ptr[513];
    if (sd_check_crc(data_ptr, crc)) {
      sd_panic_idle(40, crc);
      signal SDread.readDone[cur_cid](blk_start, data_ptr, FAIL);
      return;
    }

    /*
     * sometimes.  not sure of the conditions.  When using dma
     * the first byte will show up as 0xfe (something having
     * to do with the cmd response).  Check for this and if seen
     * flag it and re-read the buffer.  We don't keep trying so it
     * had better work.
     */
    if (data_ptr[0] == 0xfe)
      sd_warn(41, data_ptr[0]);

    last_read_time_uis = TAR - read_t0_uis;
    if (last_read_time_uis > max_read_time_uis)
      max_read_time_uis = last_read_time_uis;

    last_read_time_mis = call lt.get() - read_t0_mis;
    if (last_read_time_mis > max_read_time_mis)
      max_read_time_mis = last_read_time_mis;

    nop();
    sd_state = SDS_IDLE;
    signal SDread.readDone[cur_cid](blk_start, data_ptr, SUCCESS);
  }


  /*
   * SDread.read: read a 512 byte block from the SD
   *
   * input:  blockaddr     block to read.  (max 23 bits)
   *         data          pointer to data buffer, assumed 514 bytes
   * output: rtn           0 call successful, err otherwise
   *
   * if the return is SUCCESS, it is guaranteed that a readDone event
   * will be signalled.
   */

  command error_t SDread.read[uint8_t cid](uint32_t blockaddr, void *data) {
    sd_cmd_t *cmd;
    uint8_t   rsp;

    if (sd_state) {
      sd_panic_idle(42, sd_state);
      return EBUSY;
    }

    read_t0_uis = TAR;
    read_t0_mis = call lt.get();

    sd_state = SDS_READ;
    cur_cid = cid;
    blk_start = blockaddr;
    data_ptr = data;

    cmd = &sd_cmd;

    /* Need to add size checking, 0 = success */
    cmd->cmd = SD_READ_BLOCK;
    cmd->arg = (blk_start << SD_BLOCKSIZE_NBITS);

    if ((rsp = sd_send_command())) {
      sd_panic_idle(43, rsp);
      return FAIL;
    }

    /*
     * The SD card can take some time before it says continue.
     * We've seen upto 300-400 uis before it says continue.
     * kick to a task to let other folks run.
     */
    SD_CSN = 0;				/* rassert to continue xfer */
    sd_read_tok_count = 0;
    post sd_read_task();
    return SUCCESS;
  }


  /************************************************************************
   *
   * Write
   *
   */

  task void sd_write_task() {
    uint16_t i;
    uint8_t  tmp;

    /* card is busy writing the block.  ask if still busy. */

    tmp = sd_get();
    sd_busy_count++;
    if (tmp != 0xff) {
      post sd_write_task();
      return;
    }
    SD_CSN = 1;				/* deassert CS */

    i = sd_read_status();
    if (i)
      sd_panic(46, i);

    last_write_time_uis = TAR - write_t0_uis;
    if (last_write_time_uis > max_write_time_uis)
      max_write_time_uis = last_write_time_uis;

    last_write_time_mis = call lt.get() - write_t0_mis;
    if (last_write_time_mis > max_write_time_mis)
      max_write_time_mis = last_write_time_mis;

    nop();

    sd_state = SDS_IDLE;
    signal SDwrite.writeDone[cur_cid](blk_start, data_ptr, SUCCESS);
  }


  void sd_write_dma_handler() {
    uint8_t  tmp;
    uint16_t i;

    DMACTL0 = 0;			/* kick triggers */
    DMA0CTL = DMA1CTL = 0;		/* reset engines 0 and 1 */

    /*
     * After the data block is accepted the SD sends a data response token
     * that tells whether it accepted the block.  0x05 says all is good.
     */
    tmp = sd_get();
    if ((tmp & 0x1F) != 0x05) {
      i = sd_read_status();
      call Panic.panic(PANIC_MS, 45, tmp, i, 0, 0);
      signal SDwrite.writeDone[cur_cid](blk_start, data_ptr, FAIL);
      return;
    }

    /*
     * the SD goes busy until the block is written.  (busy is data out low).
     * we poll using a task.  The amount of time it take has been observed
     * to be about 800uis.
     */
    sd_busy_count = 0;
    sd_state = SDS_WRITE_BUSY;
    post sd_write_task();
  }


  command error_t SDwrite.write[uint8_t cid](uint32_t blockaddr, void *data) {
    sd_cmd_t *cmd;
    uint8_t  tmp, rsp;

    if (sd_state) {
      sd_panic_idle(47, sd_state);
      return EBUSY;
    }

    write_t0_uis = TAR;
    write_t0_mis = call lt.get();

    sd_state = SDS_WRITE;
    blk_start = blockaddr;
    data_ptr = data;

    cmd = &sd_cmd;

    sd_compute_crc(data);
    cmd->arg = (blk_start << SD_BLOCKSIZE_NBITS);

    cmd->cmd = SD_WRITE_BLOCK;
    if ((rsp = sd_send_command())) {
      sd_panic_idle(48, rsp);
      return FAIL;
    }

    SD_CSN = 0;				/* reassert to continue xfer */

    /* The write command needs an additional 8 clock cycles before
     * the block write is started.
     */
    tmp = sd_get();
    if (tmp != 0xff) {
      sd_panic(50, tmp);
      return FAIL;
    }

    /*
     * The SD needs a write token, send it first then fire
     * up the dma.
     */
    sd_put(SD_START_TOK);

    /* send the sector size and include the 2 crc bytes */
    sd_state = SDS_WRITE_DMA;
    sd_start_dma(data, NULL, SD_BUF_SIZE);
    DMA0_ENABLE_INT;
    return SUCCESS;
  }


  /************************************************************************
   *
   * Erase
   *
   */

  /*
   * sd_erase
   *
   * erase a contiguous number of blocks
   */

  command error_t SDerase.erase[uint8_t cid](uint32_t blk_s, uint32_t blk_e) {
    sd_cmd_t *cmd;
    uint8_t   rsp;

    if (sd_state) {
      sd_panic_idle(51, sd_state);
      return EBUSY;
    }

    sd_state = SDS_ERASE;
    cur_cid = cid;
    blk_start = blk_s;
    blk_end = blk_e;

    cmd = &sd_cmd;

    /*
     * send the start and then the end
     */
    cmd->arg = blk_start << SD_BLOCKSIZE_NBITS;
    cmd->cmd = SD_SET_ERASE_START;
    if ((rsp = sd_send_command())) {
      sd_panic_idle(52, rsp);
      return FAIL;
    }

    cmd->arg = blk_end << SD_BLOCKSIZE_NBITS;
    cmd->cmd = SD_SET_ERASE_END;
    if ((rsp = sd_send_command())) {
      sd_panic_idle(54, rsp);
      return FAIL;
    }

    cmd->cmd = SD_ERASE;
    if ((rsp = sd_send_command())) {
      sd_panic_idle(56, rsp);
      return FAIL;
    }
    return SUCCESS;
  }


  /*************************************************************************
   *
   * SDsa: standalone SD implementation, no split phase, no clients
   *
   *************************************************************************/

  command error_t SDsa.reset() {
    sd_cmd_t *cmd;                // Command Structure
    uint8_t rsp;

    cmd = &sd_cmd;
    call HW.sd_on();
    call Umod.setModeSpi((msp430_spi_union_config_t *) &sd_full_config);
    
    SD_CSN = 1;				/* force to known state */
    sd_start_dma(NULL, recv_dump, 10);	/* send 10 0xff to clock SD */
    sd_wait_dma();

    cmd->cmd = SD_FORCE_IDLE;		// Send CMD0, software reset
    cmd->arg = 0;
    rsp = sd_send_command();
    if (rsp & ~MSK_IDLE) {		/* ignore idle for errors */
      return FAIL;
    }

    do {
      cmd->cmd = SD_GO_OP;		// Send CMD0, software reset
      rsp = sd_send_acmd();
    } while (rsp & 1);
    return SUCCESS;
  }


  command error_t SDsa.read(uint32_t blk_id, void *buf) {
    return SUCCESS;
  }


  command error_t SDsa.write(uint32_t blk_id, void *buf) {
    return SUCCESS;
  }



  /*************************************************************************
   *
   * SDraw: raw interface to SD card from test programs.
   *
   *************************************************************************/

  command void SDraw.start_op() {
    SD_CSN = 0;
  }


  command void SDraw.end_op() {
    uint8_t tmp;

    tmp = sd_get();
    SD_CSN = 1;
  }


  command uint8_t SDraw.get() {
    return sd_get();
  }


  command void SDraw.put(uint8_t byte) {
    sd_put(byte);
  }


  command sd_cmd_t *SDraw.cmd_ptr() {
    return &sd_cmd;
  }


  command uint8_t SDraw.send_cmd() {
    return sd_send_command();
  }


  command uint8_t SDraw.send_acmd() {
    return sd_send_acmd();
  }


  command uint8_t SDraw.raw_cmd() {
    return sd_raw_cmd();
  }


  command void SDraw.send_recv(uint8_t *tx, uint8_t *rx, uint16_t len) {
    sd_start_dma(tx, rx, len);
    sd_wait_dma();
  }


  /*************************************************************************
   *
   * DMA interaction
   *
   *************************************************************************/


  task void dma_task() {
    switch (sd_state) {
      case SDS_READ_DMA:
	sd_read_dma_handler();
	break;

      case SDS_WRITE_DMA:
	sd_write_dma_handler();
	break;

      default:
	sd_panic(58, sd_state);
	break;
    }
  }


  TOSH_SIGNAL( DMA_VECTOR ) {
    DMA0_DISABLE_INT;
    post dma_task();
  }


#ifdef notdef
  async event void UsciInterrupts.txDone() {
    /*
     * shouldn't ever get here, we never turn intrrupts on for the ADC spi
     *
     * eventually put a panic in here.
     */
  };

  async event void UsciInterrupts.rxDone(uint8_t data) {
    /*
     * shouldn't ever get here, we never turn intrrupts on for the ADC spi
     *
     * eventually put a panic in here.
     */
  };
#endif

  default event void   SDread.readDone[uint8_t cid](uint32_t blk_id, void *buf, error_t error) {}
  default event void SDwrite.writeDone[uint8_t cid](uint32_t blk, void *buf, error_t error) {}
//  default event void SDerase.eraseDone[uint8_t cid](uint32_t blk_start, uint32_t blk_end, error_t error) {}
}
