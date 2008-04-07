/**
 * Copyright @ 2008 Eric B. Decker
 * @author Eric B. Decker
 */

configuration mm3CommDataC {
  provides interface mm3CommData[uint8_t sns_id];
}

implementation {
  components mm3CommDataP, MainC;
  mm3CommData = mm3CommDataP;
  MainC.SoftwareInit -> mm3CommDataP;

  components PanicC;
  mm3CommDataP.Panic -> PanicC;

  components mm3CommC;
  mm3CommDataP.Send     -> mm3CommC;
  mm3CommDataP.Packet   -> mm3CommC;
  mm3CommDataP.AMPacket -> mm3CommC;
}