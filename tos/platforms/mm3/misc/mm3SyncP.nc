/*
 * Copyright (c) 2008, Eric B. Decker
 * All rights reserved.
 */

/*
 * 1 min * 60 sec/min * 1024 ticks/sec  (binary millisecs, mis)
 */
#define SYNC_PERIOD (1UL * 60 * 1024)

typedef enum {
  SYNC_BOOT_NORMAL = 0,
  SYNC_BOOT_1      = 1,
  SYNC_BOOT_2      = 2,
} sync_boot_state_t;

module mm3SyncP {
  provides {
    interface Boot as OutBoot;
  }
  uses {
    interface Boot;
    interface Boot as SysBoot;
    interface Timer<TMilli> as SyncTimer;
    interface Collect;
    interface mm3CommData;
  }
}

implementation {
  sync_boot_state_t boot_state;

  /*
   * Need to rework usage of mm3CommData.send_data so if it fails
   * it still generates send_data_done.
   *
   * Otherwise, we hang in the boot sequence.  How does this work
   * when comm is down?
   */
  void write_version_record(uint8_t major, uint8_t minor, uint8_t tweak) {
    uint8_t vdata[DT_HDR_SIZE_VERSION];
    dt_version_nt *vp;

    vp = (dt_version_nt *) &vdata;
    vp->len = DT_HDR_SIZE_VERSION;
    vp->dtype = DT_VERSION;
    vp->major = major;
    vp->minor = minor;
    vp->tweak = tweak;
    call Collect.collect(vdata, DT_HDR_SIZE_VERSION);
    call mm3CommData.send_data(vdata, DT_HDR_SIZE_VERSION);
  }


  void write_sync_record(bool sync) {
    uint8_t sync_data[DT_HDR_SIZE_SYNC];
    dt_sync_nt *sdp;

    sdp = (dt_sync_nt *) &sync_data;
    sdp->len = DT_HDR_SIZE_SYNC;
    if (sync)
      sdp->dtype = DT_SYNC;
    else
      sdp->dtype = DT_SYNC_RESTART;
    sdp->stamp_mis = call SyncTimer.getNow();
    sdp->sync_majik = SYNC_MAJIK;
    call Collect.collect(sync_data, DT_HDR_SIZE_SYNC);
    call mm3CommData.send_data(sync_data, DT_HDR_SIZE_SYNC);
  }


  event void Boot.booted() {
    boot_state = SYNC_BOOT_1;
    write_version_record(1, 1, 0);
  }


  event void mm3CommData.send_data_done(error_t err) {
    switch (boot_state) {
      default:
	break;
      case SYNC_BOOT_1:
	boot_state = SYNC_BOOT_2;
	write_sync_record(FALSE);
	break;

      case SYNC_BOOT_2:
	boot_state = SYNC_BOOT_NORMAL;
	signal OutBoot.booted();
	break;
    }
  }


  event void SysBoot.booted() {
    call SyncTimer.startPeriodic(SYNC_PERIOD);
  }


  event void SyncTimer.fired() {
    write_sync_record(TRUE);
  }
}
