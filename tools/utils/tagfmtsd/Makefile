# $Id: Makefile,v 1.3 2006/07/08 07:54:11 cire Exp $
# Copyright 2006, 2010, Eric B. Decker
# Mam-Mark Project
#
# ROOT_DIR should be same as $(MM_ROOT)
#

F_DIR    = ../fat
ROOT_DIR = ../../..

INSTALL_DIR = /usr/local/bin

SOURCE  = tagfmtsd.c ms_unix.c ms_util.c util.c $(F_DIR)/fatxfc.c
OBJECTS = tagfmtsd.o fatxfc.o ms_unix.o ms_util.o util.o

CFLAGS += -g -Wall -O0 -I../fat -I. -I$(ROOT_DIR)/include
VPATH = $(F_DIR)

all: tagfmtsd

tagfmtsd: $(OBJECTS)
	$(CC) -o $@ $(LDFLAGS) $^

.c.o:
	$(CC) -c $(CFLAGS) $<

clean:
	rm -f *.o *.s *.i *~ \#*# tmp_make .#* .new*

distclean: clean
	rm -f *.a scanfat

tags:	$(SOURCE) $(F_DIR)/*.h *.h
	etags $(SOURCE) $(F_DIR)/*.h *.h

dep:
	sed '/\#\#\# Dependencies/q' <Makefile >tmp_make
	$(CPP) $(CFLAGS) -MM $(SOURCE) $(S_FAT) >>tmp_make
	mv tmp_make Makefile

install: tagfmtsd
	install -t $(INSTALL_DIR) tagfmtsd

### Dependencies
tagfmtsd.o: tagfmtsd.c ../../../include/mm_types.h \
 ../../../include/mm_byteswap.h ../fat/fat_fs.h ../fat/fatxfc.h \
 ../../../include/fs_loc.h ms.h
ms_unix.o: ms_unix.c ../../../include/mm_types.h \
 ../../../include/mm_byteswap.h ms.h ../../../include/fs_loc.h ms_util.h
ms_util.o: ms_util.c ../../../include/mm_types.h \
 ../../../include/mm_byteswap.h ms.h ../../../include/fs_loc.h ms_util.h
util.o: util.c ../../../include/mm_types.h util.h
fatxfc.o: ../fat/fatxfc.c ../../../include/mm_types.h \
 ../../../include/mm_byteswap.h ../fat/fat_fs.h ../fat/fatxfc.h \
 ../../../include/fs_loc.h ms.h util.h
