/*
 * Copyright (c) 2012, 2014, 2017 Eric B. Decker, Daniel J. Maltbie
 * All rights reserved.
 */

configuration testGPSC {}
implementation {
  components testGPSP, SystemBootC;
  testGPSP.Boot -> SystemBootC;

  components PlatformC;
  components GPS0C as GpsPort;
#ifdef notdef
  testGPSP.HW -> GpsPort;
#endif
  testGPSP.GPSState   -> GpsPort;
  testGPSP.GPSReceive -> GpsPort;
  testGPSP.Platform   -> PlatformC;

  components new TimerMilliC() as Timer;
  testGPSP.testTimer -> Timer;

  components LocalTimeMilliC;
  testGPSP.LocalTime -> LocalTimeMilliC;
}