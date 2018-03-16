#!/usr/bin/env python2
'''tagdump - dump tag data stream records'''

# Copyright (c) 2017-2018 Daniel J. Maltbie, Eric B. Decker
# All rights reserved.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
# See COPYING in the top level directory of this source tree.
#
# Contact: Daniel J. Maltbie <dmaltbie@daloma.org>
#          Eric B. Decker <cire831@gmail.com>

# Vebosity;
#
#   0   just display basic record occurance (default)
#   1   basic record display - more details
#   2   detailed record display
#   3   dump buffer/record
#   4   details of resync
#   5   other errors and decoder versions

import sys
import struct
import argparse

from   dt_defs       import *
import dt_defs       as     dtd
from   dt_defs       import print_record

import sirf_defs     as     sirf

from   tagdumpargs   import parseargs
from   misc_utils    import dump_buf

from   tagfile         import TagFile
from   tagfile         import TF_SEEK_END

from   __init__        import __version__   as VERSION
from   dt_defs         import DT_H_REVISION as DT_REV

from   dt_defs         import __version__   as dt_ver
from   decode_base     import __version__   as db_ver

# decoder files also populate dt_records and mid_table.  These are
# dictionaries of what packets we know about.  We need to make sure that
# each decoder file gets evaluated in some fashion to make sure that the
# appropriate entry has been set.
#
# "from ... import" does the right thing because it evaluates the entire
# file even though it is just importing one thing.  This causes side effects
# to occur.

from   sirf_defs       import __version__   as sb_ver
from   sirf_decoders   import __version__   as gd_ver
from   sirf_headers    import __version__   as gh_ver

from   core_decoders   import __version__   as cd_ver
from   core_headers    import __version__   as ch_ver

ver_str = '\ntagdump: ' + VERSION + ':  dt_rev ' + str(DT_REV)


####
#
# tagdump: dump a MamMark DBLKxxxx data stream.
#
# Parses the data stream and displays in human readable output.
#
# Each record is completely self contained including a checksum
# that is over both the header and data portion of the record.
# (See typed_data.h for details).
#
# see tagdumpargs.py for argument processing.
#
# usage: tagdump.py [-h] [-v] [-V] [-j JUMP] [-x EndFilePos]
#                   [--rtypes RTYPES(ints)] [--rnames RNAMES(name[,...])]
#                   [-s START_TIME] [-e END_TIME]
#                   [-r START_REC]  [-l LAST_REC]
#                   input
#
# Args:
#
# optional arguments:
#   -h              show this help message and exit
#   -V              show program's version number and exit
#
#   --rtypes RTYPES output records matching types in list names
#                   comma or space seperated list of rtype ids or NAMES
#                   (args.rtypes, list of strings)
#
#   -D              turn on Debugging information
#                   (args.debug, boolean)
#
#   -j JUMP         set input file position
#                   (args.jump, integer)
#                   -1: goto EOF
#                   negative number, offset from EOF.
#
#   -x endpos       set last file position to process
#                   (args.endpos, integer)
#
#   -n num          limit display to <num> records
#                   (args.num, integer)
#
#   --net           enable network (tagnet) i/o
#                   (args.net, boolean)
#
#   -s SYNC_DELTA   search some number of syncs backward
#                   always implies --net, -s 0 says .last_sync
#                   -s 1 and -s -1 both say sync one back.
#                   (args.sync, int)
#
#   --start START_TIME
#                   include records with datetime greater than START_TIME
#   --end END_TIME  (args.{start,end}_time)
#
#   -r START_REC    starting/ending records to dump.
#                   -r -1 says start with .last_rec (implies --net)
#   -l LAST_REC     (args.{start,last}_rec, integer)
#
#   --tail          do not stop when we run out of data.  monitor and
#                   get new data as it arrives.  (implies --net)
#                   (args.tail, boolean)
#
#   -v, --verbose   increase output verbosity
#                   (args.verbose)
#
# positional parameters:
#
#   input:          file to process.  (args.input)


# This program needs to understand the format of the DBlk data stream.
# The format of a particular instance is described by typed_data.h.
# The define DT_H_REVISION in typed_data.h indicates which version.
# Matching is a good thing.  We won't abort but will bitch if we mismatch.
#
# DT_H_REVISION is defined in headers_core.py

#
# global control cells
#
rec_low                 = 0            # inclusive
rec_high                = 0            # inclusive
rec_last                = 0            # last rec num looked at
verbose                 = 0            # how chatty to be
debug                   = 0            # extra debug chatty


# 1st sector of the first is the directory
DBLK_DIR_SIZE           = 0x200
RLEN_MAX_SIZE           = 1024
RESYNC_HDR_OFFSET       = 36            # how to get back to the start
MAX_ZERO_SIGS           = 1024          # 1024 quads, 4K bytes of zero


# global stat counters
num_resyncs             = 0             # how often we've resync'd
chksum_errors           = 0             # checksum errors seen
unk_rtypes              = 0             # unknown record types
total_records           = 0
total_bytes             = 0

def init_globals():
    global rec_low, rec_high, rec_last, verbose, debug
    global num_resyncs, chksum_errors, unk_rtypes
    global total_records, total_bytes

    rec_low             = 0
    rec_high            = 0
    rec_last            = 0
    verbose             = 0
    debug               = 0

    num_resyncs         = 0             # how often we've resync'd
    chksum_errors       = 0             # checksum errors seen
    unk_rtypes          = 0             # unknown record types
    total_records       = 0
    total_bytes         = 0


#
# resync the data stream to the next SYNC/REBOOT record
#
# we search for the SYNC_MAJIK and then back up an appropriate
# amount (RESYNC_HDR_OFFSET).  We check for reasonable length
# and reasonable rtype (SYNC or REBOOT).
#
# Once we think we have a good SYNC/REBOOT, we leave the file
# position at the start of the SYNC/REBOOT.  And let other
# checks needed be performed by gen_records.
#
# returns -1 if something went wrong
#         offset of next record if not.
#

resync0 = '*** resync: unaligned offset: {0} (0x{0:x}) -> {1} (0x{1:x})'
resync1 = '*** resync: (struct error) [len: {0}] @{1} (0x{1:x})'

def resync(fd, offset):
    global num_resyncs

    print
    print('*** resync started @{0} (0x{0:x})'.format(offset))
    if (offset & 3 != 0):
        print(resync0.format(offset, (offset/4)*4))
        offset = (offset / 4) * 4
    fd.seek(offset)
    num_resyncs += 1
    zero_sigs = 0
    v = dtd.dt_records.get(DT_SYNC,   (0, None, None, None, ''))
    sync_len   = v[DTR_REQ_LEN]
    v = dtd.dt_records.get(DT_REBOOT, (0, None, None, None, ''))
    reboot_len = v[DTR_REQ_LEN]
    if (reboot_len == 0 or sync_len == 0):
        print('*** can NOT resync, sync or reboot record not defined.')
        return -1
    while (True):
        while (True):
            try:
                offset = fd.tell()
                majik_buf = fd.read(dtd.quad_struct.size)
                sig = dtd.quad_struct.unpack(majik_buf)[0]
                if sig == dtd.dt_sync_majik:
                    break
            except struct.error:
                print(resync1.format(len(majik_buf), offset))
                return -1
            except IOError:
                print('*** resync: file io error @{}'.format(offset))
                return -1
            except EOFError:
                print('*** resync: end of file @{}'.format(offset))
                return -1
            except:
                print('*** resync: exception error: {} @{}'.format(
                    sys.exc_info()[0], offset))
                raise
            offset = fd.tell()
            if (sig == 0):
                zero_sigs += 1
                if (zero_sigs > MAX_ZERO_SIGS):
                    print('*** resync: too many zeros ({} x 4), bailing, @{}'.format(
                        MAX_ZERO_SIGS, offset))
                    return -1
            else:
                zero_sigs = 0
        fd.seek(-RESYNC_HDR_OFFSET, 1)          # back up to start of attempt
        offset_try = fd.tell()
        if (verbose >= 4):
            print('*** resync: found MAJIK @{0} (0x{0:x})'.format(offset))
        buf = bytearray(fd.read(dtd.dt_hdr_size))
        if (len(buf) < dtd.dt_hdr_size):            # oht oh, too small, very strange
            print('*** resync: read of dt_hdr too small, @{}'.format(offset_try))
            return -1

        # we want rlen and rtype, we leave recsum checking for gen_records
        rlen, rtype, recnum, systime, recsum = dtd.dt_hdr_struct.unpack(buf)
        if ((rtype == DT_SYNC   and rlen == sync_len) or
            (rtype == DT_REBOOT and rlen == reboot_len)):
            fd.seek(offset_try)
            return offset_try

        # not what we expected.  continue looking for SYNC_MAJIKs where we left off
        if (verbose >= 4):
            resync2 = '*** resync: failed len/rtype @{} (0x{:x}): ' + \
                      'len: {}, type: {}, rec: {}'
            print(resync2.format(offset_try, offset_try, rlen, rtype, recnum))
            print('    moving to: @{0} (0x{0:x})'.format(
                offset_try + RESYNC_HDR_OFFSET))
        fd.seek(offset_try + RESYNC_HDR_OFFSET)


def get_record(fd):
    """
    Generate valid typed-data records one at a time until no more bytes
    to read from the input file.

    Yields one record each time (len, type, recnum, systime, recsum, rec_buf).

    Input:   fd:         file descriptor we are reading from
    Output:  rec_offset: byte offset of the record from start of file
             rlen:       record length
             rtype:      record type
             recnum      record number
             systime     time since last reboot
             recsum      checksum ovr header and data
             rec_buf:    byte buffer with entire record
    """

    global chksum_errors

    # output variables
    offset      = -1
    rlen        = 0
    rtype       = 0
    recnum      = 0
    systime     = 0
    recsum      = 0
    rec_buf     = bytearray()
    align0 = '*** aligning offset {0} (0x{0:x}) -> {1} (0x{1:x}) [{2} bytes]'

    last_offset = 0                     # protects against infinite resync

    while (True):
        offset = fd.tell()
        # new records are required to start on a quad boundary
        if (offset & 3):
            new_offset = ((offset/4) + 1) * 4
            if debug:
                print(align0.format(offset, new_offset, new_offset - offset))
            offset = new_offset
            fd.seek(offset)
        if (offset == last_offset):
            #
            # offset/last_offset being equal says we are doing a resync
            # and we ended back at the same record.
            #
            # advance our current position to just beyond the last sync we
            # tried.  Find the next one.
            #
            offset += RESYNC_HDR_OFFSET
            print('*** resyncing: moving past current majik to: @{0} (0x{0:x})'.format(
                offset))
            offset = resync(fd, offset)
            if (offset < 0):
                break
            continue
        last_offset = offset
        rec_buf = bytearray(fd.read(dtd.dt_hdr_size))
        if (len(rec_buf) < dtd.dt_hdr_size):
            print('*** record header read too short: wanted {}, got {}, @{}'.format(
                dtd.dt_hdr_size, len(rec_buf), offset))
            break                       # oops
        rlen, rtype, recnum, systime, recsum = dtd.dt_hdr_struct.unpack(rec_buf)

        # check for obvious errors
        if (rlen < dtd.dt_hdr_size):
            print('*** record size too small: {}, @{}'.format(rlen, offset))
            offset = resync(fd, offset)
            if (offset < 0):
                break
            continue

        if (rlen > RLEN_MAX_SIZE):
            print('*** record size too large: {}, @{}'.format(rlen, offset))
            offset = resync(fd, offset)
            if (offset < 0):
                break
            continue

        if (recnum == 0):               # zero is never allowed
            print('*** zero record number, @{} - resyncing'.format(offset))
            offset = resync(fd, offset)
            if (offset < 0):
                break
            continue

        # now see if we have any data payload
        # if dlen is negative, that says we are below min header size
        dlen = rlen - dtd.dt_hdr_size
        if (dlen < 0):                  # major oops, rlen is screwy
            print('*** record header too short: wanted {}, got {}, @{}'.format(
                dtd.dt_hdr_size, rlen, offset))
            offset = resync(fd, offset)
            if (offset < 0):
                break
            continue

        if (dlen > 0):
            rec_buf.extend(bytearray(fd.read(dlen)))

        if (len(rec_buf) < rlen):
            print('*** record read too short: wanted {}, got {}, @{}'.format(
                rlen, len(rec_buf), offset))
            break                       # oops, bail

        # verify checksum.
        #
        # sum the entire record (byte by byte) and then remove the bytes from recsum.
        # recsum was computed with the field being 0 and then layed down
        # so we need to remove it before comparing.  Recsum is 16 bits wide so can not
        # simply be added in as part of the checksum computation.
        #
        chksum = sum(rec_buf)
        chksum -= (recsum & 0xff00) >> 8
        chksum -= (recsum & 0x00ff)
        chksum &= 0xffff                # force to 16 bits vs. 16 bit recsum
        if (chksum != recsum):
            chksum_errors += 1
            chksum1 = '*** checksum failure @{0} (0x{0:x}) ' + \
                      '[wanted: 0x{1:x}, got: 0x{2:x}]'
            print(chksum1.format(offset, recsum, chksum))
            print_record(offset, rec_buf)
            if (verbose >= 3):
                print
                dump_buf(rec_buf, '    ')
            offset = resync(fd, offset)
            if (offset < 0):
                break
            continue                    # try again
        try:
            required_len = dtd.dt_records[rtype][DTR_REQ_LEN]
            if (required_len):
                if (required_len != rlen):
                    offset = resync(fd, offset)
                    if (offset < 0):
                        break
                    continue            # try again
        except KeyError:
            pass

        # life is good.  return actual record.
        return offset, rlen, rtype, recnum, systime, recsum, rec_buf

    # oops.  things blew up.  just return -1 for the offset
    return -1, 0, 0, 0, 0, 0, ''


def process_dir(fd):
    fd.seek(DBLK_DIR_SIZE)


def dump(args):
    """
    Reads records and prints out details

    A dt-specific decoder is selected for each type of record which
    determines the output

    The input 'args' contains a list of the user input parameters that
    determine which records to print, including: start, end, type

    Summary information is output after all records have been processed,
    including: number of records output, counts for each record type,
    and dt-specific decoder summary
    """

    global rec_low, rec_high, rec_last, verbose, debug
    global num_resyncs, chksum_errors, unk_rtypes
    global total_records, total_bytes

    init_globals()

    if (args.verbose and args.verbose >= 5):
        print ver_str
        print '  decode_base: {}  dt_defs: {}  sirf_defs: {}'.format(
            db_ver, dt_ver, sb_ver)
        print '     core:  d: {}  h: {}'.format(cd_ver, ch_ver)
        print '     gps :  d: {}  h: {}'.format(gd_ver, gh_ver)
        print

    def count_dt(rtype):
        """
        increment counter in dict of rtypes, create new entry if needed
        also check for existence of dtd.dt_records entry.  If not known
        count it as unknown.
        """
        global unk_rtypes

        try:
            dtd.dt_records[rtype]
        except KeyError:
            unk_rtypes += 1

        try:
            dtd.dt_count[rtype] += 1
        except KeyError:
            dtd.dt_count[rtype] = 1

    # Any -s argument (walk syncs backward) or -r -1 (last_rec) forces net io
    if (args.sync is not None or args.start_rec == -1 or args.tail):
        args.net = True

    # create file object that handles both buffered and direct io
    infile  = TagFile(args.input, net_io = args.net, tail = args.tail)
    verbose = args.verbose if (args.verbose) else 0
    debug   = args.debug   if (args.debug)   else 0

    if (args.start_rec):
        rec_low  = args.start_rec
    if (args.last_rec):
        rec_high = args.last_rec

    # convert any args.rtypes to upper case

    # process the directory, this will leave us pointing at the first header
    process_dir(infile)

    if (args.jump):
        if (args.jump == -1):
            infile.seek(0, how = TF_SEEK_END)
        elif (args.jump < 0):
            infile.seek(args.jump, how = TF_SEEK_END)
        else:
            infile.seek(args.jump)

    print(dtd.rec_title_str)

    # extract record from input file and output decoded results
    try:
        while(True):
            rec_offset, rlen, rtype, recnum, systime, recsum, rec_buf = \
                    get_record(infile)
            if (rec_offset < 0):
                break;

            if (recnum < rec_last):
                print('*** recnum went backwards.  last: {}, new: {}, @{}'.format(
                    rec_last, recnum, rec_offset))
            if (rec_last and recnum > rec_last + 1):
                print('*** record gap: ({}) records, @{}'.format(
                    recnum - rec_last, rec_offset))
            rec_last = recnum

            # apply any filters (inclusion)
            if (args.rtypes):
                # either the number rtype must be in the search list
                # or the name of the rtype must be in the search list
                if ((str(rtype)       not in args.rtypes) and
                      (dt_name(rtype) not in args.rtypes)):
                    continue                   # not an rtype of interest

            # look to see if record number bounds
            if (rec_low and recnum < rec_low):
                continue
            if (rec_high and recnum > rec_high):
                break                       # all done

            # look to see if past file position bound
            if (args.endpos and rec_offset > args.endpos):
                break                       # all done

            count_dt(rtype)
            v = dtd.dt_records.get(rtype, (0, None, None, None, ''))
            decode   = v[DTR_DECODER]           # dt function
            emitters = v[DTR_EMITTERS]          # emitter list
            obj      = v[DTR_OBJ]               # dt object
            if (decode):
                try:
                    decode(verbose, rec_offset, rec_buf, obj)
                    if emitters and len(emitters):
                        for e in emitters:
                            e(verbose, rec_offset, rec_buf, obj)
                except struct.error:
                    print('*** decoder/emitter error: (len: {}, '
                          'rtype: {} {}), @{}'.format(
                              rlen, rtype, dt_name(rtype), rec_offset))
            else:
                if (verbose >= 5):
                    print('*** no decoder installed for rtype {}, @{}'.format(
                        rtype, rec_offset))
            if (verbose >= 3):
                print
                print_record(rec_offset, rec_buf)
                dump_buf(rec_buf, '    ')
            if (verbose >= 1):
                print
            total_records += 1
            total_bytes   += rlen
            if (args.num and total_records >= args.num):
                break
    except KeyboardInterrupt:
        print
        print
        print('*** user stop'),

    print
    print('*** end of processing @{} (0x{:x}),  processed: {} records, {} bytes'.format(
        infile.tell(), infile.tell(), total_records, total_bytes))
    print('*** reboots: {}, resyncs: {}, chksum_errs: {}, unk_rtypes: {}'.format(
        dtd.dt_count.get(DT_REBOOT, 0), num_resyncs, chksum_errors, unk_rtypes))
    print
    print('dt_s:  {}'.format(dtd.dt_count))
    print('mid_s: {}'.format(sirf.mid_count))

if __name__ == "__main__":
    dump(parseargs())
