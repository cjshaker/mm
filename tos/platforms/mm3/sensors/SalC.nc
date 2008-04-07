/*
 * Copyright (c) 2008, Eric B. Decker
 * All rights reserved.
 */

#include "sensors.h"

configuration SalC {
  provides interface StdControl;
}

implementation {
  components MainC, SalP;
  MainC.SoftwareInit -> SalP;
  StdControl = SalP;

  components RegimeC, new TimerMilliC() as PeriodTimer;
  SalP.RegimeCtrl -> RegimeC.Regime;
  SalP.PeriodTimer -> PeriodTimer;

  components AdcC;
  SalP.Adc -> AdcC.Adc[SNS_ID_SAL];
  AdcC.SensorPowerControl[SNS_ID_SAL] -> SalP;

  components AdcP;
  SalP.AdcConfigure <- AdcP.Config[SNS_ID_SAL];

  components CollectC;
  SalP.Collect -> CollectC;

  components HplMM3AdcC;
  SalP.HW -> HplMM3AdcC;

  components mm3ControlC;
  SalP.mm3Control -> mm3ControlC.mm3Control[SNS_ID_SAL];

  components mm3CommDataC;
  SalP.mm3CommData -> mm3CommDataC.mm3CommData[SNS_ID_SAL];

  components PanicC;
  SalP.Panic -> PanicC;
}
