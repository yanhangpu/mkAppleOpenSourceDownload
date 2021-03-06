/*
 * Copyright (c) 1999-2007 Apple Inc.  All Rights Reserved.
 * 
 * @APPLE_LICENSE_HEADER_START@
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

/***********************************************************************
* objc-initialize.m
* +initialize support
**********************************************************************/

/***********************************************************************
 * Thread-safety during class initialization (GrP 2001-9-24)
 *
 * Initial state: CLS_INITIALIZING and CLS_INITIALIZED both clear. 
 * During initialization: CLS_INITIALIZING is set
 * After initialization: CLS_INITIALIZING clear and CLS_INITIALIZED set.
 * CLS_INITIALIZING and CLS_INITIALIZED are never set at the same time.
 * CLS_INITIALIZED is never cleared once set.
 *
 * Only one thread is allowed to actually initialize a class and send 
 * +initialize. Enforced by allowing only one thread to set CLS_INITIALIZING.
 *
 * Additionally, threads trying to send messages to a class must wait for 
 * +initialize to finish. During initialization of a class, that class's 
 * method cache is kept empty. objc_msgSend will revert to 
 * class_lookupMethodAndLoadCache, which checks CLS_INITIALIZED before 
 * messaging. If CLS_INITIALIZED is clear but CLS_INITIALIZING is set, 
 * the thread must block, unless it is the thread that started 
 * initializing the class in the first place. 
 *
 * Each thread keeps a list of classes it's initializing. 
 * The global classInitLock is used to synchronize changes to CLS_INITIALIZED 
 * and CLS_INITIALIZING: the transition to CLS_INITIALIZING must be 
 * an atomic test-and-set with respect to itself and the transition 
 * to CLS_INITIALIZED.
 * The global classInitWaitCond is used to block threads waiting for an 
 * initialization to complete. The classInitLock synchronizes
 * condition checking and the condition variable.
 **********************************************************************/

/***********************************************************************
 *  +initialize deadlock case when a class is marked initializing while 
 *  its superclass is initialized. Solved by completely initializing 
 *  superclasses before beginning to initialize a class.
 *
 *  OmniWeb class hierarchy:
 *                 OBObject 
 *                     |    ` OBPostLoader
 *                 OFObject
 *                 /     \
 *      OWAddressEntry  OWController
 *                        | 
 *                      OWConsoleController
 *
 *  Thread 1 (evil testing thread):
 *    initialize OWAddressEntry
 *    super init OFObject
 *    super init OBObject		     
 *    [OBObject initialize] runs OBPostLoader, which inits lots of classes...
 *    initialize OWConsoleController
 *    super init OWController - wait for Thread 2 to finish OWController init
 *
 *  Thread 2 (normal OmniWeb thread):
 *    initialize OWController
 *    super init OFObject - wait for Thread 1 to finish OFObject init
 *
 *  deadlock!
 *
 *  Solution: fully initialize super classes before beginning to initialize 
 *  a subclass. Then the initializing+initialized part of the class hierarchy
 *  will be a contiguous subtree starting at the root, so other threads 
 *  can't jump into the middle between two initializing classes, and we won't 
 *  get stuck while a superclass waits for its subclass which waits for the 
 *  superclass.
 **********************************************************************/

#include <pthread.h>
#include <assert.h>

#import "objc-private.h"
#import "objc-initialize.h"

/* classInitLock protects classInitWaitCond and examination and modification 
 * of CLS_INITIALIZED and CLS_INITIALIZING. */
static OBJC_DECLARE_LOCK(classInitLock);

/* classInitWaitCond is signalled when any class is done initializing. 
 * Threads that are waiting for a class to finish initializing wait on this. */
static pthread_cond_t classInitWaitCond = PTHREAD_COND_INITIALIZER;


/***********************************************************************
* struct _objc_initializing_classes
* Per-thread list of classes currently being initialized by that thread. 
* During initialization, that thread is allowed to send messages to that 
* class, but other threads have to wait.
* The list is a simple array of metaclasses (the metaclass stores 
* the initialization state). 
**********************************************************************/
typedef struct _objc_initializing_classes {
    int classesAllocated;
    Class *metaclasses;
} _objc_initializing_classes;


/***********************************************************************
* _fetchInitializingClassList
* Return the list of classes being initialized by this thread.
* If create == YES, create the list when no classes are being initialized by this thread.
* If create == NO, return NULL when no classes are being initialized by this thread.
**********************************************************************/
static _objc_initializing_classes *_fetchInitializingClassList(BOOL create)
{
    _objc_pthread_data *data;
    _objc_initializing_classes *list;
    Class *classes;

    data = _objc_fetch_pthread_data(create);
    if (data == NULL  &&  !create) return NULL;

    list = data->initializingClasses;
    if (list == NULL) {
        if (!create) {
            return NULL;
        } else {
            list = _calloc_internal(1, sizeof(_objc_initializing_classes));
            data->initializingClasses = list;
        }
    }

    classes = list->metaclasses;
    if (classes == NULL) {
        // If _objc_initializing_classes exists, allocate metaclass array, 
        // even if create == NO.
        // Allow 4 simultaneous class inits on this thread before realloc.
        list->classesAllocated = 4;
        classes = _calloc_internal(list->classesAllocated, sizeof(Class));
        list->metaclasses = classes;
    }
    return list;
}


/***********************************************************************
* _destroyInitializingClassList
* Deallocate memory used by the given initialization list. 
* Any part of the list may be NULL.
* Called from _objc_pthread_destroyspecific().
**********************************************************************/
__private_extern__ 
void _destroyInitializingClassList(struct _objc_initializing_classes *list)
{
    if (list != NULL) {
        if (list->metaclasses != NULL) {
            _free_internal(list->metaclasses);
        }
        _free_internal(list);
    }
}


/***********************************************************************
* _thisThreadIsInitializingClass
* Return TRUE if this thread is currently initializing the given class.
**********************************************************************/
static BOOL _thisThreadIsInitializingClass(Class cls)
{
    int i;

    _objc_initializing_classes *list = _fetchInitializingClassList(NO);
    if (list) {
        cls = _class_getMeta(cls);
        for (i = 0; i < list->classesAllocated; i++) {
            if (cls == list->metaclasses[i]) return YES;
        }
    }

    // no list or not found in list
    return NO;
}


/***********************************************************************
* _setThisThreadIsInitializingClass
* Record that this thread is currently initializing the given class. 
* This thread will be allowed to send messages to the class, but 
*   other threads will have to wait.
**********************************************************************/
static void _setThisThreadIsInitializingClass(Class cls)
{
    int i;
    _objc_initializing_classes *list = _fetchInitializingClassList(YES);
    cls = _class_getMeta(cls);
  
    // paranoia: explicitly disallow duplicates
    for (i = 0; i < list->classesAllocated; i++) {
        if (cls == list->metaclasses[i]) {
            _objc_fatal("thread is already initializing this class!");
            return; // already the initializer
        }
    }
  
    for (i = 0; i < list->classesAllocated; i++) {
        if (0   == list->metaclasses[i]) {
            list->metaclasses[i] = cls;
            return;
        }
    }

    // class list is full - reallocate
    list->classesAllocated = list->classesAllocated * 2 + 1;
    list->metaclasses = _realloc_internal(list->metaclasses, list->classesAllocated * sizeof(Class));
    // zero out the new entries
    list->metaclasses[i++] = cls;
    for ( ; i < list->classesAllocated; i++) {
        list->metaclasses[i] = NULL;
    }
}


/***********************************************************************
* _setThisThreadIsNotInitializingClass
* Record that this thread is no longer initializing the given class. 
**********************************************************************/
static void _setThisThreadIsNotInitializingClass(Class cls)
{
    int i;

    _objc_initializing_classes *list = _fetchInitializingClassList(NO);
    if (list) {
        cls = _class_getMeta(cls);
        for (i = 0; i < list->classesAllocated; i++) {
            if (cls == list->metaclasses[i]) {
                list->metaclasses[i] = NULL;
                return;
            }
        }
    }

    // no list or not found in list
    _objc_fatal("thread is not initializing this class!");  
}


/***********************************************************************
* class_initialize.  Send the '+initialize' message on demand to any
* uninitialized class. Force initialization of superclasses first.
*
* Called only from _class_lookupMethodAndLoadCache (or itself).
**********************************************************************/
__private_extern__ void _class_initialize(Class cls)
{
    Class supercls;
    BOOL reallyInitialize = NO;

    // Get the real class from the metaclass. The superclass chain 
    // hangs off the real class only.
    cls = _class_getNonMetaClass(cls);

    // Make sure super is done initializing BEFORE beginning to initialize cls.
    // See note about deadlock above.
    supercls = _class_getSuperclass(cls);
    if (supercls  &&  !_class_isInitialized(supercls)) {
        _class_initialize(supercls);
    }
    
    // Try to atomically set CLS_INITIALIZING.
    OBJC_LOCK(&classInitLock);
    if (!_class_isInitialized(cls) && !_class_isInitializing(cls)) {
        _class_setInitializing(cls);
        reallyInitialize = YES;
    }
    OBJC_UNLOCK(&classInitLock);
    
    if (reallyInitialize) {
        // We successfully set the CLS_INITIALIZING bit. Initialize the class.
        
        // Record that we're initializing this class so we can message it.
        _setThisThreadIsInitializingClass(cls);
        
        // Send the +initialize message.
        // Note that +initialize is sent to the superclass (again) if 
        // this class doesn't implement +initialize. 2157218
        if (PrintInitializing) {
            _objc_inform("INITIALIZE: calling +[%s initialize]",
                         _class_getName(cls));
        }
        [(id)cls initialize];
        
        // propagate finalization affinity.
        if (UseGC && supercls && _class_shouldFinalizeOnMainThread(supercls)) {
            _class_setFinalizeOnMainThread(cls);
        }
        
        // Done initializing. Update the info bits and notify waiting threads.
        OBJC_LOCK(&classInitLock);
        _class_setInitialized(cls);
        pthread_cond_broadcast(&classInitWaitCond);
        OBJC_UNLOCK(&classInitLock);
        _setThisThreadIsNotInitializingClass(cls);
        return;
    }
    
    else if (_class_isInitializing(cls)) {
        // We couldn't set INITIALIZING because INITIALIZING was already set.
        // If this thread set it earlier, continue normally.
        // If some other thread set it, block until initialize is done.
        // It's ok if INITIALIZING changes to INITIALIZED while we're here, 
        //   because we safely check for INITIALIZED inside the lock 
        //   before blocking.
        if (_thisThreadIsInitializingClass(cls)) {
            return;
        } else {
            OBJC_LOCK(&classInitLock);
            while (!_class_isInitialized(cls)) {
                pthread_cond_wait(&classInitWaitCond, &classInitLock);
            }
            OBJC_UNLOCK(&classInitLock);
            return;
        }
    }
    
    else if (_class_isInitialized(cls)) {
        // Set CLS_INITIALIZING failed because someone else already 
        //   initialized the class. Continue normally.
        // NOTE this check must come AFTER the ISINITIALIZING case.
        // Otherwise: Another thread is initializing this class. ISINITIALIZED 
        //   is false. Skip this clause. Then the other thread finishes 
        //   initialization and sets INITIALIZING=no and INITIALIZED=yes. 
        //   Skip the ISINITIALIZING clause. Die horribly.
        return;
    }
    
    else {
        // We shouldn't be here. 
        _objc_fatal("thread-safe class init in objc runtime is buggy!");
    }
}
