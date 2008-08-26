/*
 * Copyright (c) 2008 Eric B. Decker
 * All rights reserved.
 *
 * Misc defines and constants for the sirf chipset.
 */

#ifndef __SIRF_H__
#define __SIRF_H__

#define SIRF_BIN_START   0xa0
#define SIRF_BIN_START_2 0xa2
#define SIRF_BIN_END     0xb0
#define SIRF_BIN_END_2   0xb3

/*
 * BUF_SIZE is biggest packet (MID 41, 91 bytes),
 *   SirfBin overhead (start, len, chksum, end) 8 bytes
 *   DT overhead (8 bytes).   107 rounded up to 128.
 *
 * GPS_OVR_SIZE: size of overflow buffer.  Space for bytes coming
 *   in on interrupts while we are processing the previous msg.
 *
 * GPS_START_OFFSET: offset into the msg buffer where the incoming bytes
 *   should be put.  Skips over DT overhead.
 *
 * GPS_OVERHEAD: space in msg buffer for overhead bytes.
 */

#define GPS_BUF_SIZE	  128
#define GPS_OVR_SIZE	   32
#define GPS_START_OFFSET    8
#define SIRF_OVERHEAD       8
#define GPS_OVERHEAD	   16

#define MID_GEODETIC	   41
#define GEODETIC_LEN	   91

/*
 * nmea_go_sirf_bin: tell the gps in nmea mode to go into sirf binary.
 * checksum for 115200 is 04, 57600 is 37
 */

uint8_t nmea_go_sirf_bin[] = {
  '$', 'P', 'S', 'R', 'F',		// header
  '1', '0', '0', ',',			// set serial port MID
  '0', ',',				// protocol 0 SirfBinary, 1 - NEMA
  '5', '7', '6', '0', '0', ',',		// baud rate
  '8', ',',				// 8 data bits
  '1', ',',				// 1 stop bit
  '0',					// no parity
  '*', '3', '7',			// checksum
  '\r', '\n'				// terminator
};


/*
 * Boot up sequence commands:
 *
 * 1) Send SW ver
 * 2) poll clock status
 * 3) poll MID 41, Geodetic data
 */

uint8_t sirf_send_boot[] = {
  0xa0, 0xa2,
  0x00, 0x02,
  132,				// send sw ver
  0x00,
  0x00, 0x84,
  0xb0, 0xb3,

  0xa0, 0xa2,
  0x00, 0x02,
  144,				// poll clock status
  0x00,
  0x00, 0x90,
  0xb0, 0xb3,

  0xa0, 0xa2,
  0x00, 0x08,
  166,				// set message rate
  1,				// send now
  41,				// mid to be set
  1,				// update rate
  0, 0, 0, 0,
  0x00, 0xd1,
  0xb0, 0xb3,

  0xa0, 0xa2,
  0x00, 0x08,
  166,				// set message rate
  0,				// send now
  2,				// mid 2, nav data
  0,				// update rate, off
  0, 0, 0, 0,
  0x00, 0xa8,
  0xb0, 0xb3,

  0xa0, 0xa2,
  0x00, 0x08,
  166,				// set message rate
  0,				// send now
  27,				// dgps status
  0,				// update rate, off
  0, 0, 0, 0,
  0x00, 0xc1,
  0xb0, 0xb3,

#ifdef notdef
  0xa0, 0xa2,
  0x00, 0x02,
  146,				// poll almanac
  0,
  0x00, 0x92,
  0xb0, 0xb3
#endif
};


uint8_t sirf_poll[] = {
  0xa0, 0xa2,			// start sequence
  0x00, 0x08,			// length
  166,				// set message rate
  1,				// send now
  41,				// mid to be set
  1,				// update rate (turn off)
  0, 0, 0, 0,			// pad
  0x00, 0xd1,			// checksum
  0xb0, 0xb3,			// end seq

  0xa0, 0xa2,
  0x00, 0x08,
  166,				// set message rate
  1,				// send now
  4,				// Tracker Data Out
  1,				// update rate
  0, 0, 0, 0,
  0x00, 0xac,
  0xb0, 0xb3,

  0xa0, 0xa2,
  0x00, 0x02,
  146,				// poll almanac
  0,
  0x00, 0x92,
  0xb0, 0xb3
};


#ifdef TEST_GPS_FUTZ

uint8_t sirf_go_nmea[] = {
  0xa0, 0xa2,			// start seq
  0x00, 0x18,			// len 24 (0x18)
  129,				// set nmea
  2,			        // mode, 0 enable nmea debug, 1 disable, 2 don't change.
  1, 1,				// GGA 1 sec period, checksum
  0, 1,				// GLL
  1, 1,	                        // GSA
  5, 1,				// GSV (5 sec period)
  1, 1,				// RMC
  0, 1,				// VTG
  0, 1,				// MSS
  0, 0,				// Unused
  0, 1,				// ZDA
  0, 0,				// Unused
  0x12, 0xc0,			// Baud rate (4800) (big endian)
  0x01, 0x65,			// checksum
  0xb0, 0xb3			// end seq
};

#endif

/*
 * The only packet we are really interested in is the Geodetic.  I has
 * both the time and position information.  Too bad it is so large.
 */

typedef nx_struct gps_geodetic {
  nx_uint8_t  start;
  nx_uint8_t  start_2;
  nx_uint16_t len;
  nx_uint8_t  mid;
  nx_uint16_t nav_valid;
  nx_uint16_t nav_type;
  nx_uint16_t ex_week;
  nx_uint32_t tow;			/* seconds x 1e3 */
  nx_uint16_t utc_year;
  nx_uint8_t  utc_month;
  nx_uint8_t  utc_day;
  nx_uint8_t  utc_hour;
  nx_uint8_t  utc_min;
  nx_uint16_t utc_sec;			/* x 1e3 (millisecs) */
  nx_uint32_t sat_mask;
  nx_uint32_t lat;			/* +N, 1e7 degrees */
  nx_uint32_t lon;			/* +E, 1e7 degrees */
  nx_uint32_t alt_ellipsoid;
  nx_uint32_t alt_msl;
  nx_uint8_t  map_datum;
  nx_uint16_t sog;
  nx_uint16_t cog;
  nx_uint16_t mag_var;
  nx_uint16_t climb;
  nx_uint16_t heading_rate;
  nx_uint32_t ehpe;			/* estimated horz pos err, 1e2 */
  nx_uint32_t evpe;			/* vert, 1e2 */
  nx_uint32_t ete;			/* est. time error, 1e2 */
  nx_uint16_t ehve;			/* est horz vel err, 1e2 */
  nx_uint32_t clock_bias;
  nx_uint32_t clock_bias_err;
  nx_uint32_t clock_drift;
  nx_uint32_t clock_drift_err;
  nx_uint32_t distance;
  nx_uint16_t distance_err;
  nx_uint16_t heading_err;
  nx_uint8_t  num_svs;
  nx_uint8_t  hdop;			/* hdop x 5 */
  nx_uint8_t  additional_mode;
  nx_uint16_t checksum;
  nx_uint8_t  end;
  nx_uint8_t  end_2;
} gps_geodetic_nt;  

#endif	/* __SIRF_H__ */
