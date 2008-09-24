/*
 * mm3dump.h - common defines
 *
 * Copyright 2008 Eric B. Decker
 * Mam-Mark Project
 */

#ifndef __MM3DUMP_H__
#define __MM3DUMP_H__

#define VERSION "mm3dump: v0.9 1 Sep 2008\n"

/*
 * Make sure this matches the defines in sd_block.h
 * we don't share header files but rather rely on ncg
 * to extract enums but if we make these enums they
 * are too big and generate an ISO C90 warning.  Screw
 * it.  They aren't likely to change so we #define them.
 */
#define SYNC_MAJIK 0xdedf00ef

#endif		// __MM3DUMP_H__