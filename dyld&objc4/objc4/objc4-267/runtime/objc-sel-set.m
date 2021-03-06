/*
 * Copyright (c) 2004 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Copyright (c) 1999-2003 Apple Computer, Inc.  All Rights Reserved.
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

/*
 * objc-sel-set.h
 * A cut-down copy of CFSet used for SEL uniquing.
 */


// NOTE: even on a 64-bit system, the implementation is still limited
// to 32-bit integers (like, the count), but SEL can be any size.

#include <stdint.h>
#import "objc-private.h"
#import "objc-sel-set.h"

static const uint32_t __objc_sel_set_capacities[43] = {
    4, 8, 17, 29, 47, 76, 123, 199, 322, 521, 843, 1364, 2207, 3571, 5778, 9349,
    15127, 24476, 39603, 64079, 103682, 167761, 271443, 439204, 710647, 1149851, 1860498,
    3010349, 4870847, 7881196, 12752043, 20633239, 33385282, 54018521, 87403803, 141422324,
    228826127, 370248451, 599074578, 969323029, 1568397607, 2537720636U, UINT32_MAX
};

static const uint32_t __objc_sel_set_buckets[42] = {    // primes
   5, 11, 23, 41, 67, 113, 199, 317, 521, 839, 1361, 2207, 3571, 5779, 9349, 15121,
   24473, 39607, 64081, 103681, 167759, 271429, 439199, 710641, 1149857, 1860503, 3010349,
   4870843, 7881193, 12752029, 20633237, 33385273, 54018521, 87403763, 141422317, 228826121,
   370248451, 599074561, 969323023, 1568397599, 2537720629U, 4106118251U
};

struct __objc_sel_set {
    uint32_t _count;            /* number of slots used */
    uint32_t _capacity;         /* maximum number of used slots */
    uint32_t _bucketsNum;       /* number of slots */
    SEL *_buckets;              /* can be NULL if not allocated yet */
};

struct __objc_sel_set_finds {
    SEL match;
    uint32_t nomatch;
};

// candidate may not be 0; match is 0 if not present
static struct __objc_sel_set_finds __objc_sel_set_findBuckets(struct __objc_sel_set *sset, SEL candidate) {
    struct __objc_sel_set_finds ret = {0, 0xffffffff};
    uint32_t probe = (uint32_t)_objc_strhash((const char *)candidate) % sset->_bucketsNum;
    for (;;) {
        SEL currentSel = sset->_buckets[probe];
        if (!currentSel) {
            ret.nomatch = probe;
            return ret;
        } else if (!ret.match && 0 == _objc_strcmp((const char *)currentSel, (const char *)candidate)) {
            ret.match = currentSel;
        }
        probe++;
        if (sset->_bucketsNum <= probe) {
            probe -= sset->_bucketsNum;
        }
    }
}

// create a set with given starting capacity, will resize as needed
__private_extern__ struct __objc_sel_set *__objc_sel_set_create(uint32_t capacity) {
    struct __objc_sel_set *sset = _malloc_internal(sizeof(struct __objc_sel_set));
    if (!sset) _objc_fatal("objc_sel_set failure");
    sset->_count = 0;
    uint32_t idx;
    for (idx = 0; __objc_sel_set_capacities[idx] < capacity; idx++);
    if (42 <= idx) _objc_fatal("objc_sel_set failure");
    sset->_capacity = __objc_sel_set_capacities[idx];
    sset->_bucketsNum = __objc_sel_set_buckets[idx];
    sset->_buckets = _calloc_internal(sset->_bucketsNum, sizeof(SEL));
    if (!sset->_buckets) _objc_fatal("objc_sel_set failure");
    return sset;
}

// returns 0 on failure; candidate may not be 0
__private_extern__ SEL __objc_sel_set_get(struct __objc_sel_set *sset, SEL candidate) {
    return __objc_sel_set_findBuckets(sset, candidate).match;
}

// value may not be 0; should not be called unless it is known the value is not in the set
__private_extern__ void __objc_sel_set_add(struct __objc_sel_set *sset, SEL value) {
    if (sset->_count == sset->_capacity) {
        SEL *oldbuckets = sset->_buckets;
        uint32_t oldnbuckets = sset->_bucketsNum;
        uint32_t idx, capacity = sset->_count + 1;
        for (idx = 0; __objc_sel_set_capacities[idx] < capacity; idx++);
        if (42 <= idx) _objc_fatal("objc_sel_set failure");
        sset->_capacity = __objc_sel_set_capacities[idx];
        sset->_bucketsNum = __objc_sel_set_buckets[idx];
        sset->_buckets = _calloc_internal(sset->_bucketsNum, sizeof(SEL));
        if (!sset->_buckets) _objc_fatal("objc_sel_set failure");
        for (idx = 0; idx < oldnbuckets; idx++) {
            SEL currentSel = oldbuckets[idx];
            if (currentSel) {
                uint32_t nomatch = __objc_sel_set_findBuckets(sset, currentSel).nomatch;
                sset->_buckets[nomatch] = currentSel;
            }
        }
        _free_internal(oldbuckets);
    }
    uint32_t nomatch = __objc_sel_set_findBuckets(sset, value).nomatch;
    sset->_buckets[nomatch] = value;
    sset->_count++;
}
