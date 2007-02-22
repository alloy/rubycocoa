/** -*-objc-*-
 *
 *   $Id$
 *
 *   Copyright (c) 2001 FUJIMOTO Hisakuni
 *
 **/

#import <objc/objc-class.h>
#import <Foundation/Foundation.h>
#import "ocdata_conv.h"
#import "RBObject.h"
#import "mdl_osxobjc.h"
#import <CoreFoundation/CFString.h> // CFStringEncoding
#import "st.h"
#import "BridgeSupport.h"
#import "internal_macros.h"

#define CACHE_LOCKING 0

#define DATACONV_LOG(fmt, args...) DLOG("DATACNV", fmt, ##args)

static struct st_table *rb2ocCache;
static struct st_table *oc2rbCache;

#if CACHE_LOCKING
static pthread_mutex_t rb2ocCacheLock;
static pthread_mutex_t oc2rbCacheLock;
# define CACHE_LOCK(x)      (pthread_mutex_lock(x))
# define CACHE_UNLOCK(x)    (pthread_mutex_unlock(x))
#else
# define CACHE_LOCK(x)
# define CACHE_UNLOCK(x)
#endif

#if MAC_OS_X_VERSION_MAX_ALLOWED <= MAC_OS_X_VERSION_10_4
// On MacOS X 10.4 or earlier, +signatureWithObjCTypes: is a SPI 
@interface NSMethodSignature (WarningKiller)
+ (id) signatureWithObjCTypes:(const char*)types;
@end
#endif

@interface RBObject (Private)
- (id)_initWithRubyObject: (VALUE)rbobj retains: (BOOL) flag;
@end

void init_rb2oc_cache(void)
{
  rb2ocCache = st_init_numtable();
#if CACHE_LOCKING
  pthread_mutex_init(&rb2ocCacheLock, NULL);
#endif
}

void init_oc2rb_cache(void)
{
  oc2rbCache = st_init_numtable();
#if CACHE_LOCKING
  pthread_mutex_init(&oc2rbCacheLock, NULL);
#endif
}

void remove_from_oc2rb_cache(id ocid)
{
  CACHE_LOCK(&oc2rbCacheLock);
  st_delete(oc2rbCache, (st_data_t *)&ocid, NULL);
  CACHE_UNLOCK(&oc2rbCacheLock);
}

void remove_from_rb2oc_cache(VALUE rbobj)
{
  CACHE_LOCK(&rb2ocCacheLock);
  st_delete(rb2ocCache, (st_data_t *)&rbobj, NULL);
  CACHE_UNLOCK(&rb2ocCacheLock);
}

size_t
ocdata_size(const char* octype_str)
{
  size_t result;
  struct bsBoxed *bs_boxed;

  if (*octype_str == _C_CONST)
    octype_str++;  

  bs_boxed = find_bs_boxed_by_encoding(octype_str);
  if (bs_boxed != NULL)
    return bs_boxed_size(bs_boxed);

  if (find_bs_cf_type_by_encoding(octype_str) != NULL)
    octype_str = "@";

  result = 0;

  switch (*octype_str) {
    case _C_ID:
    case _C_CLASS:
      result = sizeof(id); 
      break;

    case _C_SEL:
      result = sizeof(SEL); 
      break;

    case _C_CHR:
    case _C_UCHR:
      result = sizeof(char); 
      break;

    case _C_SHT:
    case _C_USHT:
      result = sizeof(short); 
      break;

    case _C_INT:
    case _C_UINT:
      result = sizeof(int); 
      break;

    case _C_LNG:
    case _C_ULNG:
      result = sizeof(long); 
      break;

#if HAVE_LONG_LONG
    case _C_LNG_LNG:
      result = sizeof(long long); 
      break;

    case _C_ULNG_LNG:
      result = sizeof(unsigned long long); 
      break;
#endif

    case _C_FLT:
      result = sizeof(float); 
      break;

    case _C_DBL:
      result = sizeof(double); 
      break;

    case _C_CHARPTR:
      result = sizeof(char*); 
      break;

    case _C_VOID:
      result = 0; 
      break;

    case _C_BOOL:
      result = sizeof(BOOL); 
      break; 

    case _C_PTR:
      result = sizeof(void*); 
      break;

    case _C_BFLD:
      if (octype_str != NULL) {
        char *type;
        long lng;
  
        type = (char *)octype_str;
        lng  = strtol(type, &type, 10);
  
        // while next type is a bit field
        while (*type == _C_BFLD) {
          long next_lng;
  
          // skip over _C_BFLD
          type++;
  
          // get next bit field length
          next_lng = strtol(type, &type, 10);
  
          // if spans next word then align to next word
          if ((lng & ~31) != ((lng + next_lng) & ~31))
            lng = (lng + 31) & ~31;
  
          // increment running length
          lng += next_lng;
        }
        result = (lng + 7) / 8;
      }
      break;

    default:
      NSGetSizeAndAlignment(octype_str, (unsigned int *)&result, NULL);
      break;
  }

  return result;
}

void *
ocdata_malloc(const char* octype_str)
{
  size_t s = ocdata_size(octype_str);
  if (s == 0) return NULL;
  return malloc(s);
}

BOOL
ocdata_to_rbobj (VALUE context_obj, const char *octype_str, const void *ocdata, VALUE *result, BOOL from_libffi)
{
  BOOL f_success = YES;
  VALUE rbval = Qnil;
  struct bsBoxed *bs_boxed;

#if BYTE_ORDER == BIG_ENDIAN
  // libffi casts all types as a void pointer, which is problematic on PPC for types sized less than a void pointer (char, uchar, short, ushort, ...), as we have to shift the bytes to get the real value.
  if (from_libffi) {
    int delta = sizeof(void *) - ocdata_size(octype_str);
    if (delta > 0)
      ocdata += delta; 
  }
#endif

  if (*octype_str == _C_CONST)
    octype_str++;

  bs_boxed = find_bs_boxed_by_encoding(octype_str);
  if (bs_boxed != NULL) {
    *result = rb_bs_boxed_new_from_ocdata(bs_boxed, (void *)ocdata);
    return YES;
  }
  
  if (find_bs_cf_type_by_encoding(octype_str) != NULL)
    octype_str = "@";

  switch (*octype_str) {
    case _C_ID:
    case _C_CLASS:
      rbval = ocid_to_rbobj(context_obj, *(id*)ocdata);
      break;

    case _C_PTR:
      if (is_boxed_ptr(octype_str, &bs_boxed)) {
        rbval = rb_bs_boxed_ptr_new_from_ocdata(bs_boxed, *(void **)ocdata);
      }
      else {
        rbval = objcptr_s_new_with_cptr (*(void**)ocdata, octype_str);
      }
       break;

    case _C_BOOL:
      rbval = bool_to_rbobj(*(BOOL*)ocdata);
      break;

    case _C_SEL:
      rbval = rb_str_new2(sel_getName(*(SEL*)ocdata));
      break;

    case _C_CHR:
      rbval = INT2NUM(*(char*)ocdata); 
      break;

    case _C_UCHR:
      rbval = UINT2NUM(*(unsigned char*)ocdata); 
      break;

    case _C_SHT:
      rbval = INT2NUM(*(short*)ocdata); 
      break;

    case _C_USHT:
      rbval = UINT2NUM(*(unsigned short*)ocdata); 
      break;

    case _C_INT:
      rbval = INT2NUM(*(int*)ocdata); 
      break;

    case _C_UINT:
      rbval = UINT2NUM(*(unsigned int*)ocdata);
      break;

    case _C_LNG:
      rbval = INT2NUM(*(long*)ocdata); 
      break;

    case _C_ULNG:
      rbval = UINT2NUM(*(unsigned long*)ocdata); 
      break;

#if HAVE_LONG_LONG
    case _C_LNG_LNG:
      rbval = LL2NUM(*(long long*)ocdata); 
      break;

    case _C_ULNG_LNG:
      rbval = ULL2NUM(*(unsigned long long*)ocdata); 
      break;
#endif

    case _C_FLT:
      rbval = rb_float_new((double)(*(float*)ocdata)); 
      break;

    case _C_DBL:
      rbval = rb_float_new(*(double*)ocdata); 
      break;

    case _C_CHARPTR:
      rbval = rb_str_new2(*(char**)ocdata); 
      break;
  
    default:
      f_success = NO;
      rbval = Qnil;
      break;
	}

  if (f_success) 
    *result = rbval;

  return f_success;
}

static BOOL 
rbary_to_nsary (VALUE rbary, id* nsary)
{
  long i;
  long len = RARRAY(rbary)->len;
  VALUE* items = RARRAY(rbary)->ptr;
  NSMutableArray* result = [[[NSMutableArray alloc] init] autorelease];
  for (i = 0; i < len; i++) {
    id nsitem;
    if (!rbobj_to_nsobj(items[i], &nsitem)) return NO;
    [result addObject: nsitem];
  }
  *nsary = result;
  return YES;
}

// FIXME: we should use the CoreFoundation API for x_to_y functions
// (should be faster than Foundation)

static BOOL 
rbhash_to_nsdic (VALUE rbhash, id* nsdic)
{
  VALUE ary_keys;
  VALUE* keys;
  VALUE val;
  long i, len;
  NSMutableDictionary* result;
  id nskey, nsval;

  ary_keys = rb_funcall(rbhash, rb_intern("keys"), 0);
  len = RARRAY(ary_keys)->len;
  keys = RARRAY(ary_keys)->ptr;

  result = [[[NSMutableDictionary alloc] init] autorelease];

  for (i = 0; i < len; i++) {
    if (!rbobj_to_nsobj(keys[i], &nskey)) return NO;
    val = rb_hash_aref(rbhash, keys[i]);
    if (!rbobj_to_nsobj(val, &nsval)) return NO;
    [result setObject: nsval forKey: nskey];
  }
  *nsdic = result;
  return YES;
}

static BOOL 
rbbool_to_nsnum (VALUE rbval, id* nsval)
{
  *nsval = [NSNumber numberWithBool:RTEST(rbval)];
  return YES;
}

static BOOL 
rbnum_to_nsnum (VALUE rbval, id* nsval)
{
  BOOL result;
  VALUE rbstr = rb_obj_as_string(rbval);
  id nsstr = [NSString stringWithUTF8String: STR2CSTR(rbstr)];
  *nsval = [NSDecimalNumber decimalNumberWithString: nsstr];
  result = [(*nsval) isKindOfClass: [NSDecimalNumber class]];
  return result;
}

static void
__slave_nsobj_free (void *p)
{
  DATACONV_LOG("releasing RBObject %p", p);
  [(id)p release];
}

static BOOL 
rbobj_convert_to_nsobj (VALUE obj, id* nsobj)
{
  switch (TYPE(obj)) {
    case T_NIL:
      *nsobj = nil;
      return YES;

    case T_STRING:
      obj = rb_obj_as_string(obj);
      *nsobj = rbstr_to_ocstr(obj);
      return YES;

    case T_SYMBOL:
      obj = rb_obj_as_string(obj);
      *nsobj = [NSString stringWithUTF8String: RSTRING(obj)->ptr];
      return YES;

    case T_ARRAY:
      return rbary_to_nsary(obj, nsobj);

    case T_HASH:
      return rbhash_to_nsdic(obj, nsobj);

    case T_TRUE:
    case T_FALSE:
      return rbbool_to_nsnum(obj, nsobj);     

    case T_FIXNUM:
    case T_BIGNUM:
    case T_FLOAT:
      return rbnum_to_nsnum(obj, nsobj);

    default:
      if (!OBJ_FROZEN(obj)) {
        *nsobj = [[RBObject alloc] _initWithRubyObject:obj retains:YES];
        // Let's embed the ObjC object in a custom Ruby object that will 
        // autorelease the ObjC object when collected by the Ruby GC, and
        // put the Ruby object as an instance variable.
        VALUE slave_nsobj;
        slave_nsobj = Data_Wrap_Struct(rb_cData, NULL, __slave_nsobj_free, *nsobj);   
        rb_ivar_set(obj, rb_intern("@__slave_nsobj__"), slave_nsobj);
      }
      else {
        // Ruby object is frozen, so we can't do much now.
        *nsobj = [[[RBObject alloc] initWithRubyObject:obj] autorelease];
      }
      return YES;
  }
  return YES;
}

BOOL 
rbobj_to_nsobj (VALUE obj, id* nsobj)
{
  BOOL  ok;

  if (obj == Qnil) {
    *nsobj = nil;
    return YES;
  }

  // Cache new Objective-C object addresses in an internal table to 
  // avoid duplication.
  //
  // We are locking the access to the cache twice (lookup + insert) as
  // rbobj_convert_to_nsobj is succeptible to call us again, to avoid
  // a deadlock.

  CACHE_LOCK(&rb2ocCacheLock);
  ok = st_lookup(rb2ocCache, (st_data_t)obj, (st_data_t *)nsobj);
  CACHE_UNLOCK(&rb2ocCacheLock);

  if (!ok) {
    *nsobj = rbobj_get_ocid(obj);
    if (*nsobj != nil || rbobj_convert_to_nsobj(obj, nsobj)) {
      BOOL  magic_cookie;

      magic_cookie = find_magic_cookie_const_by_value(*nsobj) != NULL;
      if (magic_cookie || ([*nsobj isProxy] && [*nsobj isRBObject])) {
        CACHE_LOCK(&rb2ocCacheLock);
        // Check out that the hash is still empty for us, to avoid a race condition.
        if (!st_lookup(rb2ocCache, (st_data_t)obj, (st_data_t *)nsobj))
          st_insert(rb2ocCache, (st_data_t)obj, (st_data_t)*nsobj);
        CACHE_UNLOCK(&rb2ocCacheLock);
      }
      ok = YES;
    }
  }

  return ok;
}

BOOL 
rbobj_to_bool (VALUE obj)
{
  return ((obj != Qnil) && (obj != Qfalse)) ? YES : NO;
}

VALUE 
bool_to_rbobj (BOOL val)
{
  return (val ? Qtrue : Qfalse);
}

VALUE 
sel_to_rbobj (SEL val)
{
  VALUE rbobj;

  // FIXME: this should be optimized

  if (ocdata_to_rbobj(Qnil, ":", &val, &rbobj, NO)) {
    rbobj = rb_obj_as_string(rbobj);
    // str.tr!(':','_')
    rb_funcall(rbobj, rb_intern("tr!"), 2, rb_str_new2(":"), rb_str_new2("_"));
    // str.sub!(/_+$/,'')
    rb_funcall(rbobj, rb_intern("sub!"), 2, rb_str_new2("_+$"), rb_str_new2(""));
  }
  else {
    rbobj = Qnil;
  }
  return rbobj;
}

VALUE 
int_to_rbobj (int val)
{
  return INT2NUM(val);
}

VALUE 
uint_to_rbobj (unsigned int val)
{
  return UINT2NUM(val);
}

VALUE 
double_to_rbobj (double val)
{
  return rb_float_new(val);
}

VALUE
ocid_to_rbobj_cache_only (id ocid)
{
  VALUE result;
  BOOL  ok;

  CACHE_LOCK(&oc2rbCacheLock);
  ok = st_lookup(oc2rbCache, (st_data_t)ocid, (st_data_t *)&result);
  CACHE_UNLOCK(&oc2rbCacheLock);

  return ok ? result : Qnil;
}

VALUE
ocid_to_rbobj (VALUE context_obj, id ocid)
{
  VALUE result;
  BOOL  ok;

  if (ocid == nil) 
    return Qnil;

  // Cache new Ruby object addresses in an internal table to 
  // avoid duplication.
  //
  // We are locking the access to the cache twice (lookup + insert) as
  // ocobj_s_new is succeptible to call us again, to avoid a deadlock.

  CACHE_LOCK(&oc2rbCacheLock);
  ok = st_lookup(oc2rbCache, (st_data_t)ocid, (st_data_t *)&result);
  CACHE_UNLOCK(&oc2rbCacheLock);

  if (!ok) {
    struct bsConst *  bs_const;

    bs_const = find_magic_cookie_const_by_value(ocid);
    if (bs_const != NULL) {
      result = ocobj_s_new_with_class_name(ocid, bs_const->class_name);
    }
    else {
      result = ocid_get_rbobj(ocid);
      if (result == Qnil)
        result = rbobj_get_ocid(context_obj) == ocid ? context_obj : ocobj_s_new(ocid);
    }

    CACHE_LOCK(&oc2rbCacheLock);
    // Check out that the hash is still empty for us, to avoid a race condition.
    if (!st_lookup(oc2rbCache, (st_data_t)ocid, (st_data_t *)&result))
      st_insert(oc2rbCache, (st_data_t)ocid, (st_data_t)result);
    CACHE_UNLOCK(&oc2rbCacheLock);
  }

  return result;
}

const char * 
rbobj_to_cselstr (VALUE obj)
{
  int i;
  VALUE str;
  
  if (rb_obj_is_kind_of(obj, rb_cString)) {
    str = rb_str_dup(obj);
  } else {
    str = rb_obj_as_string(obj);
  }

  // str[0..0] + str[1..-1].tr('_',':')
  for (i = 1; i < RSTRING(str)->len; i++) {
    if (RSTRING(str)->ptr[i] == '_')
      RSTRING(str)->ptr[i] = ':';
  }
  return STR2CSTR(str);
}

SEL 
rbobj_to_nssel (VALUE obj)
{
  return NIL_P(obj) ? NULL : sel_registerName(rbobj_to_cselstr(obj));
}

static BOOL 
rbobj_to_objcptr (VALUE obj, void** cptr)
{
  if (TYPE(obj) == T_NIL) {
    *cptr = NULL;
  }
  else if (TYPE(obj) == T_STRING) {
    *cptr = RSTRING(obj)->ptr;
  }
#if 0
  // TODO
  else if (TYPE(obj) == T_ARRAY) {
    if (RARRAY(obj)->len > 0) {
      void *ary;
      unsigned i;

      ary = *cptr;
      for (i = 0; i < RARRAY(obj)->len; i++) {
        rbobj_to_ocdata( )
      }
    }
    else {
      *cptr = NULL;
    }
  }
#endif
  else if (rb_obj_is_kind_of(obj, objid_s_class()) == Qtrue) {
    *cptr = OBJCID_ID(obj);
  }
  else if (rb_obj_is_kind_of(obj, objcptr_s_class()) == Qtrue) {
    *cptr = objcptr_cptr(obj);
  }
  else if (rb_obj_is_kind_of(obj, objboxed_s_class()) == Qtrue) {
    struct bsBoxed *bs_boxed;
    void *data;
    BOOL ok;

    bs_boxed = find_bs_boxed_for_klass(CLASS_OF(obj));
    if (bs_boxed == NULL)
      return NO;

    data = rb_bs_boxed_get_data(obj, bs_boxed->encoding, NULL, &ok);
    if (!ok)
      return NO;
    *cptr = data;
  } 
  else {
    return NO;
  }
  return YES;
}

static BOOL 
rbobj_to_idptr (VALUE obj, id** idptr)
{
  if (TYPE(obj) == T_NIL) {
    *idptr = nil;
  }
  else if (TYPE(obj) == T_ARRAY) {
    if (RARRAY(obj)->len > 0) {
      id *ary;
      unsigned i;

      ary = *idptr;
      for (i = 0; i < RARRAY(obj)->len; i++) {
        if (!rbobj_to_nsobj(RARRAY(obj)->ptr[i], &ary[i])) {
          *idptr = nil;
          return NO;
        }
      }
    }
    else {
      *idptr = nil;
    }
  }
  else if (rb_obj_is_kind_of(obj, objid_s_class()) == Qtrue) {
    id old_id = OBJCID_ID(obj);
    if (old_id) [old_id release];
    OBJCID_ID(obj) = nil;
    *idptr = OBJCID_IDPTR(obj);
  }
  else {
    return NO;
  }
  return YES;
}

BOOL
rbobj_to_ocdata (VALUE obj, const char *octype_str, void* ocdata, BOOL to_libffi)
{
  BOOL f_success = YES;
  struct bsBoxed *bs_boxed;

#if BYTE_ORDER == BIG_ENDIAN
  // libffi casts all types as a void pointer, which is problematic on PPC for types sized less than a void pointer (char, uchar, short, ushort, ...), as we have to shift the bytes to get the real value.
  if (to_libffi) {
    int delta = sizeof(void *) - ocdata_size(octype_str);
    if (delta > 0)
      ocdata += delta; 
  }
#endif
  
  if (*octype_str == _C_CONST)
    octype_str++;

  // Make sure we convert booleans to NSNumber booleans.
  if (*octype_str != _C_ID) {
    if (TYPE(obj) == T_TRUE) {
      obj = INT2NUM(1);
    }
    else if (TYPE(obj) == T_FALSE) {
      obj = INT2NUM(0);
    }
  }

  if (find_bs_boxed_by_encoding(octype_str) != NULL) {
    void *data;
    size_t size;

    data = rb_bs_boxed_get_data(obj, octype_str, &size, &f_success);
    if (f_success) {
      if (data == NULL)
        *(void **)ocdata = NULL;
      else
        memcpy(ocdata, data, size);
      return YES;
    }
  }

  if (find_bs_cf_type_by_encoding(octype_str) != NULL)
    octype_str = "@";

  switch (*octype_str) {
    case _C_ID:
    case _C_CLASS: 
    {
      id nsobj;
      f_success = rbobj_to_nsobj(obj, &nsobj);
      if (f_success) *(id*)ocdata = nsobj;
      break;
    }

    case _C_SEL:
      *(SEL*)ocdata = rbobj_to_nssel(obj);
      break;

    case _C_UCHR:
    case _C_BOOL:
      *(unsigned char*)ocdata = (unsigned char) NUM2UINT(rb_Integer(obj));
      break;

    case _C_CHR:
      *(char*)ocdata = (char) NUM2INT(rb_Integer(obj));
      break;

    case _C_SHT:
      *(short*)ocdata = (short) NUM2INT(rb_Integer(obj));
      break;

    case _C_USHT:
      *(unsigned short*)ocdata = (unsigned short) NUM2UINT(rb_Integer(obj));
      break;

    case _C_INT:
      *(int*)ocdata = (int) NUM2INT(rb_Integer(obj));
      break;

    case _C_UINT:
      *(unsigned int*)ocdata = (unsigned int) NUM2UINT(rb_Integer(obj));
      break;

    case _C_LNG:
      *(long*)ocdata = (long) NUM2LONG(rb_Integer(obj));
      break;

    case _C_ULNG:
      *(unsigned long*)ocdata = (unsigned long) NUM2ULONG(rb_Integer(obj));
      break;

#if HAVE_LONG_LONG
    case _C_LNG_LNG:
      *(long long*)ocdata = (long long) NUM2LL(rb_Integer(obj));
      break;

    case _C_ULNG_LNG:
      *(unsigned long long*)ocdata = (unsigned long long) NUM2ULL(rb_Integer(obj));
      break;
#endif

    case _C_FLT:
      *(float*)ocdata = (float) RFLOAT(rb_Float(obj))->value;
      break;

    case _C_DBL:
      *(double*)ocdata = RFLOAT(rb_Float(obj))->value;
      break;

    case _C_CHARPTR:
      *(char**)ocdata = STR2CSTR(rb_obj_as_string(obj));
      break;

    case _C_PTR:
      bs_boxed = NULL;
      if (is_id_ptr(octype_str)) {
        f_success = rbobj_to_idptr(obj, ocdata);
      }
#if 0
      else if (is_boxed_ptr(octype_str, &bs_boxed)) {
        void *data = rb_bs_boxed_get_data(obj, bs_boxed->encoding, NULL, &f_success);
        *(void **)ocdata = &data;
      }
#endif
      else {
        f_success = rbobj_to_objcptr(obj, ocdata);
      }
      break;

    default:
      f_success = NO;
      break;
  }

  return f_success;
}

static 
NSStringEncoding kcode_to_nsencoding (const char* kcode) 
{ 
  if (strcmp(kcode, "UTF8") == 0)
    return NSUTF8StringEncoding;
  else if (strcmp(kcode, "SJIS") == 0)
    return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingMacJapanese);
  else if (strcmp(kcode, "EUC") == 0)
    return NSJapaneseEUCStringEncoding;
  else // "NONE"
    return NSUTF8StringEncoding;
}
#define KCODE_NSSTRENCODING kcode_to_nsencoding(rb_get_kcode()) 

id
rbstr_to_ocstr(VALUE obj)
{
  return [[[NSString alloc] initWithData:[NSData dataWithBytes:RSTRING(obj)->ptr
			    			 length: RSTRING(obj)->len]
			    encoding:KCODE_NSSTRENCODING] autorelease];
}

VALUE
ocstr_to_rbstr(id ocstr)
{
  NSData * data = [(NSString *)ocstr dataUsingEncoding:KCODE_NSSTRENCODING
				     allowLossyConversion:YES];
  return rb_str_new ([data bytes], [data length]);
}

static void
__decode_method_encoding_with_method_signature(NSMethodSignature *methodSignature, unsigned *argc, char **retval_type, char ***arg_types, BOOL strip_first_two_args)
{
  *argc = [methodSignature numberOfArguments];
  if (strip_first_two_args)
    *argc -= 2;
  *retval_type = strdup([methodSignature methodReturnType]);
  if (*argc > 0) {
    unsigned i;
    char **l_arg_types;
    l_arg_types = (char **)malloc(sizeof(char *) * *argc);
    for (i = 0; i < *argc; i++)
      l_arg_types[i] = strdup([methodSignature getArgumentTypeAtIndex:i + (strip_first_two_args ? 2 : 0)]);
    *arg_types = l_arg_types;
  }
  else {
    *arg_types = NULL;
  }
}

static inline const char *
__iterate_until(const char *type, char end)
{
  char begin;
  unsigned nested;

  begin = *type;
  nested = 0;

  do {
    type++;
    if (*type == begin) {
      nested++;
    }
    else if (*type == end) {
      if (nested == 0)
        return type;
      nested--;
    }
  }
  while (YES);

  return NULL;
}

BOOL 
is_id_ptr (const char *type)
{
  if (*type != _C_PTR)
    return NO;

  type++;
  type = encoding_skip_modifiers(type);

  return *type == _C_ID; 
}

BOOL
is_boxed_ptr (const char *type, struct bsBoxed **boxed)
{
  struct bsBoxed *b;

  if (*type != _C_PTR)
    return NO;

  type++;

  b = find_bs_boxed_by_encoding(type);
  if (b != NULL) {
    if (boxed != NULL)
      *boxed = b;
    return YES;
  }

  return NO;
}

const char *
encoding_skip_modifiers(const char *type)
{
  while (YES) {
    switch (*type) {
      case _C_CONST:
      case _C_PTR:
      case 'O': // bycopy
      case 'n': // in
      case 'o': // out
      case 'N': // inout
      case 'V': // oneway
        type++;
        break;

      default:
        return type;
    }
  }
  return NULL;
}

static const char *
__get_first_encoding(const char *type, char *buf, size_t buf_len)
{
  const char *orig_type;
  const char *p;

  orig_type = type;

  type = encoding_skip_modifiers(type);

  switch (*type) {
    case '\0':
      return NULL;
    case _C_ARY_B:
      type = __iterate_until(type, _C_ARY_E);
      break;
    case _C_STRUCT_B:
      type = __iterate_until(type, _C_STRUCT_E);
      break;
    case _C_UNION_B:
      type = __iterate_until(type, _C_UNION_E);
      break;
  }

  type++;
  p = type;
  while (*p >= '0' && *p <= '9') { p++; }

  if (buf != NULL) {
    size_t len = MIN(buf_len, (long)(type - orig_type));
    strncpy(buf, orig_type, len);
    buf[len] = '\0';
  }

  return p;
}

// 10.4 or lower, use NSMethodSignature.
// Otherwise, use the Objective-C runtime API, which is faster and more reliable with structures encoding.
void
decode_method_encoding(const char *encoding, NSMethodSignature *methodSignature, unsigned *argc, char **retval_type, char ***arg_types, BOOL strip_first_two_args)
{
  assert(encoding != NULL || methodSignature != nil);

  if (encoding == NULL) {
    DATACONV_LOG("decoding method encoding using method signature %p", methodSignature);
    __decode_method_encoding_with_method_signature(methodSignature, argc, retval_type, arg_types, strip_first_two_args);   
  }
  else {
    char buf[128];

    DATACONV_LOG("decoding method encoding '%s' manually", encoding);
    encoding = __get_first_encoding(encoding, buf, sizeof buf);
    DATACONV_LOG("retval -> %s", buf);
    *retval_type = strdup(buf);
    if (strip_first_two_args) {
      DATACONV_LOG("skipping first two args");
      encoding = __get_first_encoding(encoding, NULL, 0);    
      encoding = __get_first_encoding(encoding, NULL, 0);    
    }
    *argc = 0;
    // Do a first pass to know the argc 
    if (encoding != NULL) {
      const char *p = encoding;
      while ((p = __get_first_encoding(p, NULL, 0)) != NULL) { (*argc)++; }
    }
    DATACONV_LOG("argc -> %d", *argc);
    if (*argc > 0) {
      unsigned i;
      char **p;
      i = 0;
      p = (char **)malloc(sizeof(char *) * (*argc));
      while ((encoding = __get_first_encoding(encoding, buf, sizeof buf)) != NULL) {
        DATACONV_LOG("arg[%d] -> %s\n", i, buf);
        p[i++] = strdup(buf);
      }
      *arg_types = p;
    }
  }
}
