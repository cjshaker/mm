/* -*- mode:c; indent-tabs-mode: nil; c-basic-offset: 2 -*-
/* 
 * mm3MagP.nc: implementation for Magnatometer
 * Copyright 2008 Eric B. Decker
 * All rights reserved.
 */


/**
 *  Magnatometer Sensor Driver
 *  @author: Eric B. Decker
 */

#include "sensors.h"

module mm3MagP {
  provides {
    interface StdControl;
    interface Init;
    interface AdcConfigure<const mm3_sensor_config_t*>;
  }

  uses {
    interface mm3Regime as RegimeCtrl;
    interface Timer<TMilli> as PeriodTimer;
    interface mm3Adc as Adc;
  }
}
implementation {
  uint32_t period;
  uint8_t  mag_state;
  uint32_t err_overruns;


  command error_t Init.init() {
    mag_state = SNS_STATE_OFF;
    err_overruns = 0;
    return SUCCESS;
  }


  command error_t StdControl.start() {
    period = call RegimeCtrl.sensorPeriod(SNS_ID_MAG);
    if (period) {
      call PeriodTimer.startPeriodic(period);
      mag_state = SNS_STATE_PERIOD_WAIT;
    } else
      mag_state = SNS_STATE_OFF;
    return SUCCESS;
  }


  command error_t StdControl.stop() {
    call PeriodTimer.stop();
    if (mag_state == SNS_STATE_PERIOD_WAIT)
      mag_state = SNS_STATE_OFF;
  }


  event void PeriodTimer.fired() {
    if (mag_state != SNS_STATE_PERIOD_WAIT) {
      err_overruns++;
      /*
       * bitch, shouldn't be here.  Of course it could be
       * because something took way too long.
       */
      call StdControl.start();
      return;
    }
    mag_state = SNS_STATE_ADC_WAIT;
    call Adc.request();
  }


  event void Adc.granted() {
    uint16_t data;

    data = call Adc.readAdc();
    mag_state = SNS_STATE_PERIOD_WAIT;
    call Adc.release();
  }


  event void RegimeCtrl.regimeChange() {
    uint32_t new_period;

    new_period = call RegimeCtrl.sensorPeriod(SNS_ID_MAG);
    if (new_period == 0) {
      call PeriodTimer.stop();
      if (mag_state == SNS_STATE_PERIOD_WAIT)
	mag_state = SNS_STATE_OFF;
    } else if (new_period != period) {
      period = new_period;
      call PeriodTimer.stop();
      call PeriodTimer.startPeriodic(period);
      /* leave state alone */
    }
  }


  const mm3_sensor_config_t mag_config =
    { .sns_id = SNS_ID_MAG,
      .mux  = DMUX_MAG_XY_A,
      .gmux = GMUX_x400,
      .t_powerup = 5
    };


    async command const mm3_sensor_config_t* AdcConfigure.getConfiguration() {
      return &mag_config;
    }
}
