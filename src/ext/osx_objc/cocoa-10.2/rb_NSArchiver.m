#import "osx_ruby.h"
#import "ocdata_conv.h"
#import <Foundation/Foundation.h>

extern VALUE oc_err_new (const char* fname, NSException* nsexcp);
extern void rbarg_to_nsarg(VALUE rbarg, int octype, void* nsarg, const char* fname, id pool, int index);
extern VALUE nsresult_to_rbresult(int octype, const void* nsresult, const char* fname, id pool);
static const int VA_MAX = 4;


  /**** constants ****/
// NSString * const NSInconsistentArchiveException;
static VALUE
osx_NSInconsistentArchiveException(VALUE mdl)
{
  return nsresult_to_rbresult(_C_ID, &NSInconsistentArchiveException, "NSInconsistentArchiveException", nil);
}

void init_NSArchiver(VALUE mOSX)
{
  /**** constants ****/
  rb_define_module_function(mOSX, "NSInconsistentArchiveException", osx_NSInconsistentArchiveException, 0);
}
