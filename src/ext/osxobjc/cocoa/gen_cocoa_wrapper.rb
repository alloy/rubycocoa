#
#  $Id$
#
#  Copyright (c) 2001 FUJIMOTO Hisakuni <hisa@imasy.or.jp>
#
#  This program is free software.
#  You can distribute/modify this program under the terms of
#  the GNU Lesser General Public License version 2.
#

FORCE_MODE = (ARGV.size > 0 && ARGV[0] == "-f")

require '../../../tool/och_analyzer'

def collect_src_headers(src_path, re_pat)
  File.open(src_path) {|f|
    f.map {|s|
      if m = re_pat.match(s) then
	File.join(File.dirname(src_path), m[1])
      end
    }.compact.uniq
  }
end

def collect_appkit_headers
  path = "/System/Library/Frameworks/AppKit.framework/Headers/AppKit.h"
  re = %r{^\s*#import\s*<AppKit/(\w+\.h)>}
  collect_src_headers(path, re)
end

def collect_foundation_headers
  path = '/System/Library/Frameworks/Foundation.framework/Headers/Foundation.h'
  re = %r{^\s*#import\s*<Foundation/(\w+\.h)>}
  collect_src_headers(path, re)
end

def collect_classes(pathes)
  re = /^\s*@interface\s+(\w*)\b/
  names = Array.new
  pathes.each do |path|
    File.open(path) do |f|
      names.concat f.map {|line|
	m = re.match(line)
	m[1] if m && m.size > 0
      }
    end
  end
  names.compact!
  names.uniq!
  names
end

STATIC_FUNCS = <<'STATIC_FUNCS_DEFINE'
extern void rbarg_to_nsarg(VALUE rbarg, int octype, void* nsarg, id pool, int index);
extern VALUE nsresult_to_rbresult(int octype, const void* nsresult, id pool);
static const int VA_MAX = 4;
STATIC_FUNCS_DEFINE

VA_VAR_SETS = <<'VA_VAR_SETS_DEFINE'
  /* ns_va */
  va_last = va_first + VA_MAX;
  for (i = va_first; (i < argc) && (i < va_last); i++)
    rbarg_to_nsarg(argv[i], _C_ID, &ns_va[i - va_first], pool, i);
VA_VAR_SETS_DEFINE

VA_FUNC_CALL = <<'VA_FUNC_CALL_DEFINE'
  if (argc == va_first)
    %%fname%%(%%fargs%%);
  else if (argc == (va_first + 1))
    %%fname%%(%%fargs%%,
      ns_va[0]);
  else if (argc == (va_first + 2))
    %%fname%%(%%fargs%%,
      ns_va[0], ns_va[1]);
  else if (argc == (va_first + 3))
    %%fname%%(%%fargs%%,
      ns_va[0], ns_va[1], ns_va[2]);
  else if (argc == (va_first + 4))
    %%fname%%(%%fargs%%,
      ns_va[0], ns_va[1], ns_va[2], ns_va[3]);
VA_FUNC_CALL_DEFINE

def gen_c_func_notimpl
  $notimpl_cnt += 1
  "  rb_notimplement();\n"
end

def gen_c_func_arglist(argc)
  if argc == 0 then
    "(VALUE mdl)"
  elsif argc == -1 then
    "(int argc, VALUE* argv, VALUE mdl)"
  else
    s = "(VALUE mdl"
    argc.times {|i| s.concat ", VALUE a#{i}" }
    s.concat ")"
    s
  end
end

def gen_c_func_var_defs(finfo)
  ret = ""
  finfo.args.each_with_index do |ai,index|
    ret.concat "  #{ai.type} ns_a#{index};\n"
  end
  if finfo.argc == -1 then
    ret.concat "  int va_first = #{finfo.args.size};\n"
    ret.concat "  int va_last;\n"
    ret.concat "  id ns_va[VA_MAX];\n"
    ret.concat "  int i;\n"
  end
  ret
end

def gen_c_func_var_sets(finfo)
  ret = ""
  finfo.args.each_with_index do |ai,index|
    return nil if ai.octype == :UNKNOWN
    aname = (finfo.argc == -1) ? "argv[#{index}]" : "a#{index}"
    type_str = ai.octype.to_s
    type_str = "_C_UCHR" if ai.octype == :_PRIV_C_BOOL
    ret.concat "  /* #{aname} */\n"
    ret.concat "  rbarg_to_nsarg(#{aname}, #{type_str}, "
    ret.concat "&ns_a#{index}, pool, #{index});\n"
  end
  if finfo.argc == -1 then
    ret.concat VA_VAR_SETS
  end
  ret
end

def gen_c_func_func_call(finfo)
  fargs = ((0...finfo.args.size).map{|i| "ns_a#{i}"}.join(', '))
  if finfo.argc == -1 then
    s = VA_FUNC_CALL.dup
    s.gsub! /%%fargs%%/, fargs
    if finfo.octype == :_C_VOID then
      s.gsub! /%%fname%%/, "#{finfo.name}"
    else
      s.gsub! /%%fname%%/, "ns_result = #{finfo.name}"
    end
  else
    if finfo.octype == :_C_VOID then
      s = "  #{finfo.name}("
    else
      s = "  ns_result = #{finfo.name}("
    end
    s.concat fargs
    s.concat ");\n"
  end
  s
end

def gen_c_func_conv_call(octype)
  if octype == :UNKNOWN then
    nil
  elsif octype == :_C_VOID then
    "Qnil"
  else
    "nsresult_to_rbresult(#{octype}, &ns_result, pool)"
  end
end

FUNC_BODY_TMPL = <<'FUNC_BODY_TMPL_DEFINE'
%%ns_result_defs%%
%%var_defs%%
  VALUE rb_result;
  id pool = [[NSAutoreleasePool alloc] init];
%%var_set%%
%%func_call%%
  rb_result = %%conv_call%%;
  [pool release];
  return rb_result;
FUNC_BODY_TMPL_DEFINE

def gen_c_func_body(info)
  return gen_c_func_notimpl if info.octype == :UNKNOWN
  tmpl = FUNC_BODY_TMPL.dup
  if info.octype == :_C_VOID then
    tmpl.sub! /%%ns_result_defs%%/, ''
  else
    tmpl.sub! /%%ns_result_defs%%/, "  #{info.type} ns_result;\n"
  end
  tmpl.sub! /%%var_defs%%/, gen_c_func_var_defs(info)
  unless s = gen_c_func_var_sets(info) then
    return gen_c_func_notimpl
  end
  tmpl.sub! /%%var_set%%/,  s
  tmpl.sub! /%%func_call%%/,  gen_c_func_func_call(info)
  unless s = gen_c_func_conv_call(info.octype) then
    return gen_c_func_notimpl
  end
  tmpl.sub! /%%conv_call%%/, s
  tmpl
end

def gen_c_func_body_noarg(info)
  return gen_c_func_notimpl if info.octype == :UNKNOWN
  if info.instance_of? OCHeaderAnalyzer::FuncInfo then
    if info.octype == :_C_VOID then
      "  #{info.name}();\n" +
	"  return Qnil;\n"
    else
      "  #{info.type} ns_result = #{info.name}();\n" +
	"  return nsresult_to_rbresult(#{info.octype}, &ns_result, nil);\n"
    end
  else
    "  return nsresult_to_rbresult(#{info.octype}, &#{info.name}, nil);\n"
  end
end

def gen_def_c_func(info, argc = -1)
  ret =      "// #{info.orig};\n"
  ret.concat "static VALUE\nosx_#{info.name}"
  ret.concat gen_c_func_arglist(argc)
  ret.concat "\n{\n"

  if info.name == "NSCopyBitmapFromGState" then
    ret.concat gen_c_func_notimpl # AppKit/NSGraphics.h BUG ?
  elsif argc == 0 then
    ret.concat gen_c_func_body_noarg(info)
  elsif argc > 0 then
    ret.concat gen_c_func_body(info)
  else
    ret.concat gen_c_func_body(info)
  end

  ret.concat "}\n\n"
  ret
end

def gen_def_rb_mod_func(info, argc = -1)
  ret =      "  rb_define_module_function(mOSX, \""
  ret.concat "#{info.name}\", osx_#{info.name}, #{argc});\n"
  ret
end

def gen_def_enums(och)
  enums = och.enums
  return nil if enums.size == 0
  ret = "  /**** enums ****/\n"
  enums.each do |name|
    ret.concat "  rb_define_const(mOSX, \"#{name}\", INT2NUM(#{name}));\n"
  end
  ret.concat "\n"
  ret
end

def reconfig_info(info)
  if CLASSES.find {|c| /^(const\s+)?#{c}\s*\*$/.match(info.type) } then
    info.octype = :_C_ID
  end
  if info.is_a? OCHeaderAnalyzer::FuncInfo then
    info.args.each do |i|
      if CLASSES.find {|c| /^(const\s+)?#{c}\s*\*$/.match(i.type) } then
	i.octype = :_C_ID
      end
    end
  end
end

def gen_def_consts(och)
  consts = och.constants
  return nil if consts.size == 0
  ret_a = "  /**** constants ****/\n"
  ret_b = "  /**** constants ****/\n"
  $notimpl_cnt = 0
  consts.each do |info|
    reconfig_info(info)
    ret_a.concat gen_def_c_func(info, 0)
    ret_b.concat gen_def_rb_mod_func(info, 0)
  end
  $stderr.print " : #{$notimpl_cnt}/#{consts.size} consts NG"
  $stderr.flush
  [ ret_a, ret_b ]
end

def gen_def_funcs(och)
  funcs = och.functions
  return nil if funcs.size == 0
  ret_a = "  /**** functions ****/\n"
  ret_b = "  /**** functions ****/\n"
  $notimpl_cnt = 0
  funcs.each do |info|
    reconfig_info(info)
    ret_a.concat gen_def_c_func(info, info.argc)
    ret_b.concat gen_def_rb_mod_func(info, info.argc)
  end
  $stderr.print " : #{$notimpl_cnt}/#{funcs.size} funcs NG"
  $stderr.flush
  [ ret_a, ret_b ]
end

def gen_skelton(hpath)
  och = OCHeaderAnalyzer.new(hpath)
  $stderr.print "#{och.filename}..." ; $stderr.flush
  enums = gen_def_enums(och)
  consts = gen_def_consts(och)
  funcs = gen_def_funcs(och)
  if enums || consts || funcs then
    name = och.filename.split('.')[0]
    fname = "rb_#{name}.m"
    if File.exist?(fname) then
      if FORCE_MODE then
	system "mkdir -p old"
	File.rename(fname, "old/#{fname}")
      else
	raise "'#{fname}' already exist !"
      end
    end
    File.open(fname, "w") do |f|
      f.print "\#import <LibRuby/cocoa_ruby.h>\n"
      f.print "\#import \"ocdata_conv.h\"\n"
      f.print "\#import <#{och.framework}/#{och.framework}.h>\n\n"
      f.print STATIC_FUNCS
      f.print "\n\n"
      f.print consts[0] if consts
      f.print funcs[0] if funcs
      f.print "void init_#{name}(VALUE mOSX)\n"
      f.print "{\n"
      f.print enums if enums
      f.print consts[1] if consts
      f.print funcs[1] if funcs
      f.print "}\n"
    end
  end
  $stderr.print "\n"
end

fnd_headers = collect_foundation_headers
akt_headers = collect_appkit_headers
CLASSES = collect_classes(fnd_headers) + collect_classes(akt_headers)
CLASSES.uniq!

fnd_headers.each {|hpath| gen_skelton(hpath) }
akt_headers.each {|hpath| gen_skelton(hpath) }
