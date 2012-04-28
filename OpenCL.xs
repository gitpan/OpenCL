#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define X_STACKSIZE sizeof (void *) * 512 * 1024 // 2-4mb should be enough, really
#include "xthread.h"
#include "schmorp.h"

#ifdef I_DLFCN
  #include <dlfcn.h>
#endif

// how stupid is that, the 1.2 header files define CL_VERSION_1_1,
// but then fail to define the api functions unless you ALSO define
// this. This breaks 100% of the opencl 1.1 apps, for what reason?
// after all, the functions are deprecated, not removed.
// in addition, you cannot test for this in any future-proof way.
// each time a new opencl version comes out, you need to make a new
// release.
#define CL_USE_DEPRECATED_OPENCL_1_2_APIS /* just guessing, you stupid idiots */

#ifndef PREFER_1_1
  #define PREFER_1_1 1
#endif

#if PREFER_1_1
  #define CL_USE_DEPRECATED_OPENCL_1_1_APIS
#endif

#ifdef __APPLE__
  #include <OpenCL/opencl.h>
#else
  #include <CL/opencl.h>
#endif

#ifndef CL_VERSION_1_2
  #undef PREFER_1_1
  #define PREFER_1_1 1
#endif

typedef cl_platform_id   OpenCL__Platform;
typedef cl_device_id     OpenCL__Device;
typedef cl_context       OpenCL__Context;
typedef cl_command_queue OpenCL__Queue;
typedef cl_mem           OpenCL__Memory;
typedef cl_mem           OpenCL__Buffer;
typedef cl_mem           OpenCL__BufferObj;
typedef cl_mem           OpenCL__Image;
typedef cl_mem           OpenCL__Image2D;
typedef cl_mem           OpenCL__Image3D;
typedef cl_mem           OpenCL__Memory_ornull;
typedef cl_mem           OpenCL__Buffer_ornull;
typedef cl_mem           OpenCL__Image_ornull;
typedef cl_mem           OpenCL__Image2D_ornull;
typedef cl_mem           OpenCL__Image3D_ornull;
typedef cl_sampler       OpenCL__Sampler;
typedef cl_program       OpenCL__Program;
typedef cl_kernel        OpenCL__Kernel;
typedef cl_event         OpenCL__Event;
typedef cl_event         OpenCL__UserEvent;

typedef SV *FUTURE;

/*****************************************************************************/

// name must include a leading underscore
// all of this horrors would be unneceesary if somebody wrote a proper OpenGL module
// for perl. doh.
static void *
glsym (const char *name)
{
  void *fun = 0;

  #if defined I_DLFCN && defined RTLD_DEFAULT
              fun = dlsym (RTLD_DEFAULT, name + 1);
    if (!fun) fun = dlsym (RTLD_DEFAULT, name);

    if (!fun)
      {
        static void *libgl;
        static const char *glso[] = {
          "libGL.so.1",
          "libGL.so.3",
          "libGL.so.4.0",
          "libGL.so",
          "/usr/lib/libGL.so",
          "/usr/X11R6/lib/libGL.1.dylib"
        };
        int i;

        for (i = 0; !libgl && i < sizeof (glso) / sizeof (glso [0]); ++i)
          {
            libgl = dlopen (glso [i], RTLD_LAZY);
            if (libgl)
              break;
          }

        if (libgl)
          {
                      fun = dlsym (libgl, name + 1);
            if (!fun) fun = dlsym (libgl, name);
          }
      }
  #endif

  return fun;
}

/*****************************************************************************/

/* up to two temporary buffers */
static void *
tmpbuf (size_t size)
{
  enum { buffers = 3 };
  static int idx;
  static void *buf [buffers];
  static size_t len [buffers];

  idx = (idx + 1) % buffers;

  if (len [idx] < size)
    {
      free (buf [idx]);
      len [idx] = ((size + 31) & ~4095) + 4096 - 32;
      buf [idx] = malloc (len [idx]);
    }

  return buf [idx];
}

/*****************************************************************************/

typedef struct
{
  IV iv;
  const char *name;
  #define const_iv(name) { (IV)CL_ ## name, # name },
} ivstr;

static const char *
iv2str (IV value, const ivstr *base, int count, const char *fallback)
{
  int i;
  static char strbuf [32];

  for (i = count; i--; )
    if (base [i].iv == value)
      return base [i].name;

  snprintf (strbuf, sizeof (strbuf), fallback, (int)value);

  return strbuf;
}

static const char *
enum2str (cl_uint value)
{
  static const ivstr enumstr[] = {
    #include "enumstr.h"
  };

  return iv2str (value, enumstr, sizeof (enumstr) / sizeof (enumstr [0]), "ENUM(0x%04x)");
}

static const char *
err2str (cl_int err)
{
  static const ivstr errstr[] = {
    #include "errstr.h"
  };

  return iv2str (err, errstr, sizeof (errstr) / sizeof (errstr [0]), "ERROR(%d)");
}

/*****************************************************************************/

static cl_int res;

#define FAIL(name) \
  croak ("cl" # name ": %s", err2str (res));

#define NEED_SUCCESS(name,args) \
  do { \
    res = cl ## name args; \
    \
    if (res) \
      FAIL (name); \
  } while (0)

#define NEED_SUCCESS_ARG(retdecl, name, args) \
  retdecl = cl ## name args; \
  if (res) \
    FAIL (name);

/*****************************************************************************/

static cl_context_properties *
SvCONTEXTPROPERTIES (const char *func, const char *svname, SV *sv, cl_context_properties *extra, int extracount)
{
  if (!sv || !SvOK (sv))
    if (extra)
      sv = sv_2mortal (newRV_noinc ((SV *)newAV ())); // slow, but rarely used hopefully
    else
      return 0;

  if (SvROK (sv) && SvTYPE (SvRV (sv)) == SVt_PVAV)
    {
      AV *av = (AV *)SvRV (sv);
      int i, len = av_len (av) + 1;
      cl_context_properties *p = tmpbuf (sizeof (cl_context_properties) * (len + extracount + 1));
      cl_context_properties *l = p;

      if (len & 1)
        croak ("%s: %s is not a property list (must be even number of elements)", func, svname);

      while (extracount--)
        *l++ = *extra++;

      for (i = 0; i < len; i += 2)
        {
          cl_context_properties t = SvIV (*av_fetch (av, i    , 0));
          SV *p_sv                =       *av_fetch (av, i + 1, 0);
          cl_context_properties v = SvIV (p_sv); // code below can override

          switch (t)
            {
              case CL_GLX_DISPLAY_KHR:
                if (!SvOK (p_sv))
                  {
                    void *func = glsym ("_glXGetCurrentDisplay");
                    if (func)
                      v = (cl_context_properties)((void *(*)(void))func)();
                  }
                break;

              case CL_GL_CONTEXT_KHR:
                if (!SvOK (p_sv))
                  {
                    void *func = glsym ("_glXGetCurrentContext");
                    if (func)
                      v = (cl_context_properties)((void *(*)(void))func)();
                  }
                break;

              default:
                /* unknown property, treat as int */
                break;
            }

          *l++ = t;
          *l++ = v;
        }

      *l = 0;

      return p;
    }

   croak ("%s: %s is not a property list (either undef or [type => value, ...])", func, svname);
}

/*****************************************************************************/

#define NEW_CLOBJ(class,ptr) sv_setref_pv (sv_newmortal (), class, ptr)
#define PUSH_CLOBJ(class,ptr)  PUSHs  (NEW_CLOBJ (class, ptr))
#define XPUSH_CLOBJ(class,ptr) XPUSHs (NEW_CLOBJ (class, ptr))

/* cl objects are either \$iv, or [$iv, ...] */
/* they can be upgraded at runtime to the array form */
static void *
SvCLOBJ (const char *func, const char *svname, SV *sv, const char *pkg)
{
  if (SvROK (sv) && sv_derived_from (sv, pkg))
    return (void *)SvIV (SvRV (sv));

   croak ("%s: %s is not of type %s", func, svname, pkg);
}

/*****************************************************************************/
/* callback stuff */

/* default context callback, log to stderr */
static void CL_CALLBACK
context_default_notify (const char *msg, const void *info, size_t cb, void *data)
{
  fprintf (stderr, "OpenCL Context Notify: %s\n", msg);
}

typedef struct
{
  int free_cb;
  void (*push)(void *data1, void *data2, void *data3);
} eq_vtbl;

typedef struct eq_item
{
  struct eq_item *next;
  eq_vtbl *vtbl;
  SV *cb;
  void *data1, *data2, *data3;
} eq_item;

static void (*eq_signal_func)(void *signal_arg, int value);
static void *eq_signal_arg;
static xmutex_t eq_lock = X_MUTEX_INIT;
static eq_item *eq_head, *eq_tail;

static void
eq_enq (eq_vtbl *vtbl, SV *cb, void *data1, void *data2, void *data3)
{
  eq_item *item = malloc (sizeof (eq_item));

  item->next  = 0;
  item->vtbl  = vtbl;
  item->cb    = cb;
  item->data1 = data1;
  item->data2 = data2;
  item->data3 = data3;

  X_LOCK (eq_lock);

  *(eq_head ? &eq_tail->next : &eq_head) = item;
  eq_tail = item;

  X_UNLOCK (eq_lock);

  eq_signal_func (eq_signal_arg, 0);
}

static eq_item *
eq_dec (void)
{
  eq_item *res;

  X_LOCK (eq_lock);

  res = eq_head;
  if (res)
    eq_head = res->next;

  X_UNLOCK (eq_lock);

  return res;
}

static void
eq_poll (void)
{
  eq_item *item;

  while ((item = eq_dec ()))
    {
      ENTER;
      SAVETMPS;

      dSP;
      PUSHMARK (SP);
      EXTEND (SP, 2);

      if (item->vtbl->free_cb)
        sv_2mortal (item->cb);

      PUTBACK;
      item->vtbl->push (item->data1, item->data2, item->data3);

      SV *cb = item->cb;
      free (item);

      call_sv (cb, G_DISCARD | G_VOID);

      FREETMPS;
      LEAVE;
    }
}

static void
eq_poll_interrupt (pTHX_ void *c_arg, int value)
{
  eq_poll ();
}

/*****************************************************************************/
/* context notify */

static void
eq_context_push (void *data1, void *data2, void *data3)
{
  dSP;
  PUSHs (sv_2mortal (newSVpv  (data1, 0)));
  PUSHs (sv_2mortal (newSVpvn (data2, (STRLEN)data3)));
  PUTBACK;

  free (data1);
  free (data2);
}

static eq_vtbl eq_context_vtbl = { 0, eq_context_push };

static void CL_CALLBACK
eq_context_notify (const char *msg, const void *pvt, size_t cb, void *user_data)
{
  void *pvt_copy = malloc (cb);
  memcpy (pvt_copy, pvt, cb);
  eq_enq (&eq_context_vtbl, user_data, strdup (msg), pvt_copy, (void *)cb);
}

#define CONTEXT_NOTIFY_CALLBACK \
  void (CL_CALLBACK *pfn_notify)(const char *, const void *, size_t, void *) = context_default_notify; \
  void *user_data = 0; \
  \
  if (SvOK (notify)) \
    { \
      pfn_notify = eq_context_notify; \
      user_data = s_get_cv (notify); \
    }

static SV *
new_clobj_context (cl_context ctx, void *user_data)
{
  SV *sv = NEW_CLOBJ ("OpenCL::Context", ctx);

  if (user_data)
    sv_magicext (SvRV (sv), user_data, PERL_MAGIC_ext, 0, 0, 0);

  return sv;
}

#define XPUSH_CLOBJ_CONTEXT XPUSHs (new_clobj_context (ctx, user_data));

/*****************************************************************************/
/* build/compile/link notify */

static void
eq_program_push (void *data1, void *data2, void *data3)
{
  dSP;
  PUSH_CLOBJ ("OpenCL::Program", data1);
  PUTBACK;
}

static eq_vtbl eq_program_vtbl = { 1, eq_program_push };

static void CL_CALLBACK
eq_program_notify (cl_program program, void *user_data)
{
  eq_enq (&eq_program_vtbl, user_data, (void *)program, 0, 0);
}

struct build_args
{
  cl_program program;
  char *options;
  void *user_data;
  cl_uint num_devices;
};

X_THREAD_PROC (build_program_thread)
{
  struct build_args *arg = thr_arg;

  clBuildProgram (arg->program, arg->num_devices, arg->num_devices ? (void *)(arg + 1) : 0, arg->options, 0, 0);
  
  if (arg->user_data)
    eq_program_notify (arg->program, arg->user_data);
  else
    clReleaseProgram (arg->program);

  free (arg->options);
  free (arg);
}

static void
build_program_async (cl_program program, cl_uint num_devices, const cl_device_id *device_list, const char *options, void *user_data)
{
  struct build_args *arg = malloc (sizeof (struct build_args) + sizeof (*device_list) * num_devices);

  arg->program     = program;
  arg->options     = strdup (options);
  arg->user_data   = user_data;
  arg->num_devices = num_devices;
  memcpy (arg + 1, device_list, sizeof (*device_list) * num_devices);

  xthread_t id;
  thread_create (&id, build_program_thread, arg);
}

/*****************************************************************************/
/* event objects */

static void
eq_event_push (void *data1, void *data2, void *data3)
{
  dSP;
  PUSH_CLOBJ ("OpenCL::Event", data1);
  PUSHs (sv_2mortal (newSViv ((IV)data2)));
  PUTBACK;
}

static eq_vtbl eq_event_vtbl = { 1, eq_event_push };

static void CL_CALLBACK
eq_event_notify (cl_event event, cl_int event_command_exec_status, void *user_data)
{
  clRetainEvent (event);
  eq_enq (&eq_event_vtbl, user_data, (void *)event, (void *)(IV)event_command_exec_status, 0);
}

/*****************************************************************************/

static size_t
img_row_pitch (cl_mem img)
{
  size_t res;
  clGetImageInfo (img, CL_IMAGE_ROW_PITCH, sizeof (res), &res, 0);
  return res;
}

static cl_event *
event_list (SV **items, cl_uint *rcount)
{
  cl_uint count = *rcount;

  if (!count)
    return 0;

  cl_event *list = tmpbuf (sizeof (cl_event) * count);
  int i = 0;

  do
    {
      --count;
      if (SvOK (items [count]))
        list [i++] = SvCLOBJ ("clEnqueue", "wait_events", items [count], "OpenCL::Event");
    }
  while (count);

  *rcount = i;

  return i ? list : 0;
}

#define EVENT_LIST(items,count) \
  cl_uint event_list_count = (count); \
  cl_event *event_list_ptr = event_list (&ST (items), &event_list_count)

#define INFO(class) \
{ \
	size_t size; \
	NEED_SUCCESS (Get ## class ## Info, (self, name, 0, 0, &size)); \
        SV *sv = sv_2mortal (newSV (size)); \
        SvUPGRADE (sv, SVt_PV); \
        SvPOK_only (sv); \
        SvCUR_set (sv, size); \
	NEED_SUCCESS (Get ## class ## Info, (self, name, size, SvPVX (sv), 0)); \
        XPUSHs (sv); \
}

MODULE = OpenCL		PACKAGE = OpenCL

PROTOTYPES: ENABLE

void
poll ()
	CODE:
        eq_poll ();

void
_eq_initialise (IV func, IV arg)
	CODE:
        eq_signal_func = (void (*)(void *, int))func;
        eq_signal_arg  = (void*)arg;

BOOT:
{
  HV *stash = gv_stashpv ("OpenCL", 1);
  static const ivstr *civ, const_iv[] = {
    { sizeof (cl_char  ), "SIZEOF_CHAR"   },
    { sizeof (cl_uchar ), "SIZEOF_UCHAR"  },
    { sizeof (cl_short ), "SIZEOF_SHORT"  },
    { sizeof (cl_ushort), "SIZEOF_USHORT" },
    { sizeof (cl_int   ), "SIZEOF_INT"    },
    { sizeof (cl_uint  ), "SIZEOF_UINT"   },
    { sizeof (cl_long  ), "SIZEOF_LONG"   },
    { sizeof (cl_ulong ), "SIZEOF_ULONG"  },
    { sizeof (cl_half  ), "SIZEOF_HALF"   },
    { sizeof (cl_float ), "SIZEOF_FLOAT"  },
    { sizeof (cl_double), "SIZEOF_DOUBLE" },
#include "constiv.h"
  };

  for (civ = const_iv + sizeof (const_iv) / sizeof (const_iv [0]); civ > const_iv; civ--)
    newCONSTSUB (stash, (char *)civ[-1].name, newSViv (civ[-1].iv));

  sv_setiv (perl_get_sv ("OpenCL::POLL_FUNC", TRUE), (IV)eq_poll_interrupt);
}

cl_int
errno ()
	CODE:
        RETVAL = res;
	OUTPUT:
        RETVAL

const char *
err2str (cl_int err = res)

const char *
enum2str (cl_uint value)

void
platforms ()
	PPCODE:
	cl_platform_id *list;
        cl_uint count;
        int i;

	NEED_SUCCESS (GetPlatformIDs, (0, 0, &count));
        list = tmpbuf (sizeof (*list) * count);
	NEED_SUCCESS (GetPlatformIDs, (count, list, 0));

        EXTEND (SP, count);
        for (i = 0; i < count; ++i)
          PUSH_CLOBJ ("OpenCL::Platform", list [i]);

void
context_from_type (cl_context_properties *properties = 0, cl_device_type type = CL_DEVICE_TYPE_DEFAULT, SV *notify = &PL_sv_undef)
	PPCODE:
        CONTEXT_NOTIFY_CALLBACK;
        NEED_SUCCESS_ARG (cl_context ctx, CreateContextFromType, (properties, type, 0, 0, &res));
        XPUSH_CLOBJ_CONTEXT;

void
context (FUTURE properties, FUTURE devices, FUTURE notify)
	PPCODE:
	/* der Gipfel der Kunst */

void
wait_for_events (...)
	CODE:
        EVENT_LIST (0, items);
        NEED_SUCCESS (WaitForEvents, (event_list_count, event_list_ptr));

PROTOTYPES: DISABLE

MODULE = OpenCL		PACKAGE = OpenCL::Platform

void
info (OpenCL::Platform self, cl_platform_info name)
	PPCODE:
        INFO (Platform)

void
unload_compiler (OpenCL::Platform self)
	CODE:
#if CL_VERSION_1_2
        clUnloadPlatformCompiler (self);
#endif

#BEGIN:platform

void
profile (OpenCL::Platform self)
 ALIAS:
 profile = CL_PLATFORM_PROFILE
 version = CL_PLATFORM_VERSION
 name = CL_PLATFORM_NAME
 vendor = CL_PLATFORM_VENDOR
 extensions = CL_PLATFORM_EXTENSIONS
 PPCODE:
 size_t size;
 NEED_SUCCESS (GetPlatformInfo, (self, ix,    0,     0, &size));
 char *value = tmpbuf (size);
 NEED_SUCCESS (GetPlatformInfo, (self, ix, size, value,     0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVpv (value, 0)));

#END:platform

void
devices (OpenCL::Platform self, cl_device_type type = CL_DEVICE_TYPE_ALL)
	PPCODE:
	cl_device_id *list;
        cl_uint count;
        int i;

	NEED_SUCCESS (GetDeviceIDs, (self, type, 0, 0, &count));
        list = tmpbuf (sizeof (*list) * count);
	NEED_SUCCESS (GetDeviceIDs, (self, type, count, list, 0));

        EXTEND (SP, count);
        for (i = 0; i < count; ++i)
          PUSHs (sv_setref_pv (sv_newmortal (), "OpenCL::Device", list [i]));

void
context (OpenCL::Platform self, cl_context_properties *properties, SV *devices, SV *notify = &PL_sv_undef)
	PPCODE:
        if (!SvROK (devices) || SvTYPE (SvRV (devices)) != SVt_PVAV)
          croak ("OpenCL::Platform::context argument 'device' must be an arrayref with device objects, in call");

        AV *av = (AV *)SvRV (devices);
        cl_uint num_devices = av_len (av) + 1;
        cl_device_id *device_list = tmpbuf (sizeof (cl_device_id) * num_devices);

        int i;
        for (i = num_devices; i--; )
          device_list [i] = SvCLOBJ ("clCreateContext", "devices", *av_fetch (av, i, 0), "OpenCL::Device");

        CONTEXT_NOTIFY_CALLBACK;
	NEED_SUCCESS_ARG (cl_context ctx, CreateContext, (properties, num_devices, device_list, pfn_notify, user_data, &res));
        XPUSH_CLOBJ_CONTEXT;

void
context_from_type (OpenCL::Platform self, SV *properties = 0, cl_device_type type = CL_DEVICE_TYPE_DEFAULT, SV *notify = &PL_sv_undef)
	PPCODE:
	cl_context_properties extra[] = { CL_CONTEXT_PLATFORM, (cl_context_properties)self };
        cl_context_properties *props = SvCONTEXTPROPERTIES ("OpenCL::Platform::context_from_type", "properties", properties, extra, 2);

        CONTEXT_NOTIFY_CALLBACK;
        NEED_SUCCESS_ARG (cl_context ctx, CreateContextFromType, (props, type, 0, 0, &res));
        XPUSH_CLOBJ_CONTEXT;

MODULE = OpenCL		PACKAGE = OpenCL::Device

void
info (OpenCL::Device self, cl_device_info name)
	PPCODE:
        INFO (Device)

#BEGIN:device

void
type (OpenCL::Device self)
 PPCODE:
 cl_device_type value [1];
 NEED_SUCCESS (GetDeviceInfo, (self, CL_DEVICE_TYPE, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSViv (value [i])));

void
vendor_id (OpenCL::Device self)
 ALIAS:
 vendor_id = CL_DEVICE_VENDOR_ID
 max_compute_units = CL_DEVICE_MAX_COMPUTE_UNITS
 max_work_item_dimensions = CL_DEVICE_MAX_WORK_ITEM_DIMENSIONS
 preferred_vector_width_char = CL_DEVICE_PREFERRED_VECTOR_WIDTH_CHAR
 preferred_vector_width_short = CL_DEVICE_PREFERRED_VECTOR_WIDTH_SHORT
 preferred_vector_width_int = CL_DEVICE_PREFERRED_VECTOR_WIDTH_INT
 preferred_vector_width_long = CL_DEVICE_PREFERRED_VECTOR_WIDTH_LONG
 preferred_vector_width_float = CL_DEVICE_PREFERRED_VECTOR_WIDTH_FLOAT
 preferred_vector_width_double = CL_DEVICE_PREFERRED_VECTOR_WIDTH_DOUBLE
 max_clock_frequency = CL_DEVICE_MAX_CLOCK_FREQUENCY
 max_read_image_args = CL_DEVICE_MAX_READ_IMAGE_ARGS
 max_write_image_args = CL_DEVICE_MAX_WRITE_IMAGE_ARGS
 image_support = CL_DEVICE_IMAGE_SUPPORT
 max_samplers = CL_DEVICE_MAX_SAMPLERS
 mem_base_addr_align = CL_DEVICE_MEM_BASE_ADDR_ALIGN
 min_data_type_align_size = CL_DEVICE_MIN_DATA_TYPE_ALIGN_SIZE
 global_mem_cacheline_size = CL_DEVICE_GLOBAL_MEM_CACHELINE_SIZE
 max_constant_args = CL_DEVICE_MAX_CONSTANT_ARGS
 preferred_vector_width_half = CL_DEVICE_PREFERRED_VECTOR_WIDTH_HALF
 native_vector_width_char = CL_DEVICE_NATIVE_VECTOR_WIDTH_CHAR
 native_vector_width_short = CL_DEVICE_NATIVE_VECTOR_WIDTH_SHORT
 native_vector_width_int = CL_DEVICE_NATIVE_VECTOR_WIDTH_INT
 native_vector_width_long = CL_DEVICE_NATIVE_VECTOR_WIDTH_LONG
 native_vector_width_float = CL_DEVICE_NATIVE_VECTOR_WIDTH_FLOAT
 native_vector_width_double = CL_DEVICE_NATIVE_VECTOR_WIDTH_DOUBLE
 native_vector_width_half = CL_DEVICE_NATIVE_VECTOR_WIDTH_HALF
 reference_count_ext = CL_DEVICE_REFERENCE_COUNT_EXT
 PPCODE:
 cl_uint value [1];
 NEED_SUCCESS (GetDeviceInfo, (self, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
max_work_group_size (OpenCL::Device self)
 ALIAS:
 max_work_group_size = CL_DEVICE_MAX_WORK_GROUP_SIZE
 image2d_max_width = CL_DEVICE_IMAGE2D_MAX_WIDTH
 image2d_max_height = CL_DEVICE_IMAGE2D_MAX_HEIGHT
 image3d_max_width = CL_DEVICE_IMAGE3D_MAX_WIDTH
 image3d_max_height = CL_DEVICE_IMAGE3D_MAX_HEIGHT
 image3d_max_depth = CL_DEVICE_IMAGE3D_MAX_DEPTH
 max_parameter_size = CL_DEVICE_MAX_PARAMETER_SIZE
 profiling_timer_resolution = CL_DEVICE_PROFILING_TIMER_RESOLUTION
 PPCODE:
 size_t value [1];
 NEED_SUCCESS (GetDeviceInfo, (self, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
max_work_item_sizes (OpenCL::Device self)
 PPCODE:
 size_t size;
 NEED_SUCCESS (GetDeviceInfo, (self, CL_DEVICE_MAX_WORK_ITEM_SIZES,    0,     0, &size));
 size_t *value = tmpbuf (size);
 NEED_SUCCESS (GetDeviceInfo, (self, CL_DEVICE_MAX_WORK_ITEM_SIZES, size, value,     0));
 int i, n = size / sizeof (*value);
 EXTEND (SP, n);
 for (i = 0; i < n; ++i)
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
address_bits (OpenCL::Device self)
 PPCODE:
 cl_bitfield value [1];
 NEED_SUCCESS (GetDeviceInfo, (self, CL_DEVICE_ADDRESS_BITS, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
max_mem_alloc_size (OpenCL::Device self)
 ALIAS:
 max_mem_alloc_size = CL_DEVICE_MAX_MEM_ALLOC_SIZE
 global_mem_cache_size = CL_DEVICE_GLOBAL_MEM_CACHE_SIZE
 global_mem_size = CL_DEVICE_GLOBAL_MEM_SIZE
 max_constant_buffer_size = CL_DEVICE_MAX_CONSTANT_BUFFER_SIZE
 local_mem_size = CL_DEVICE_LOCAL_MEM_SIZE
 PPCODE:
 cl_ulong value [1];
 NEED_SUCCESS (GetDeviceInfo, (self, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
single_fp_config (OpenCL::Device self)
 ALIAS:
 single_fp_config = CL_DEVICE_SINGLE_FP_CONFIG
 double_fp_config = CL_DEVICE_DOUBLE_FP_CONFIG
 half_fp_config = CL_DEVICE_HALF_FP_CONFIG
 PPCODE:
 cl_device_fp_config value [1];
 NEED_SUCCESS (GetDeviceInfo, (self, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
global_mem_cache_type (OpenCL::Device self)
 PPCODE:
 cl_device_mem_cache_type value [1];
 NEED_SUCCESS (GetDeviceInfo, (self, CL_DEVICE_GLOBAL_MEM_CACHE_TYPE, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
local_mem_type (OpenCL::Device self)
 PPCODE:
 cl_device_local_mem_type value [1];
 NEED_SUCCESS (GetDeviceInfo, (self, CL_DEVICE_LOCAL_MEM_TYPE, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
error_correction_support (OpenCL::Device self)
 ALIAS:
 error_correction_support = CL_DEVICE_ERROR_CORRECTION_SUPPORT
 endian_little = CL_DEVICE_ENDIAN_LITTLE
 available = CL_DEVICE_AVAILABLE
 compiler_available = CL_DEVICE_COMPILER_AVAILABLE
 host_unified_memory = CL_DEVICE_HOST_UNIFIED_MEMORY
 PPCODE:
 cl_bool value [1];
 NEED_SUCCESS (GetDeviceInfo, (self, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (value [i] ? &PL_sv_yes : &PL_sv_no));

void
execution_capabilities (OpenCL::Device self)
 PPCODE:
 cl_device_exec_capabilities value [1];
 NEED_SUCCESS (GetDeviceInfo, (self, CL_DEVICE_EXECUTION_CAPABILITIES, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
properties (OpenCL::Device self)
 PPCODE:
 cl_command_queue_properties value [1];
 NEED_SUCCESS (GetDeviceInfo, (self, CL_DEVICE_QUEUE_PROPERTIES, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSViv (value [i])));

void
platform (OpenCL::Device self)
 PPCODE:
 cl_platform_id value [1];
 NEED_SUCCESS (GetDeviceInfo, (self, CL_DEVICE_PLATFORM, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 {
   PUSH_CLOBJ ("OpenCL::Platform", value [i]);
 }

void
name (OpenCL::Device self)
 ALIAS:
 name = CL_DEVICE_NAME
 vendor = CL_DEVICE_VENDOR
 driver_version = CL_DRIVER_VERSION
 profile = CL_DEVICE_PROFILE
 version = CL_DEVICE_VERSION
 extensions = CL_DEVICE_EXTENSIONS
 PPCODE:
 size_t size;
 NEED_SUCCESS (GetDeviceInfo, (self, ix,    0,     0, &size));
 char *value = tmpbuf (size);
 NEED_SUCCESS (GetDeviceInfo, (self, ix, size, value,     0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVpv (value, 0)));

void
parent_device_ext (OpenCL::Device self)
 PPCODE:
 cl_device_id value [1];
 NEED_SUCCESS (GetDeviceInfo, (self, CL_DEVICE_PARENT_DEVICE_EXT, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 {
   PUSH_CLOBJ ("OpenCL::Device", value [i]);
 }

void
partition_types_ext (OpenCL::Device self)
 ALIAS:
 partition_types_ext = CL_DEVICE_PARTITION_TYPES_EXT
 affinity_domains_ext = CL_DEVICE_AFFINITY_DOMAINS_EXT
 partition_style_ext = CL_DEVICE_PARTITION_STYLE_EXT
 PPCODE:
 size_t size;
 NEED_SUCCESS (GetDeviceInfo, (self, ix,    0,     0, &size));
 cl_device_partition_property_ext *value = tmpbuf (size);
 NEED_SUCCESS (GetDeviceInfo, (self, ix, size, value,     0));
 int i, n = size / sizeof (*value);
 EXTEND (SP, n);
 for (i = 0; i < n; ++i)
 PUSHs (sv_2mortal (newSVuv (value [i])));

#END:device

MODULE = OpenCL		PACKAGE = OpenCL::Context

void
DESTROY (OpenCL::Context context)
	CODE:
        clReleaseContext (context);

void
info (OpenCL::Context self, cl_context_info name)
	PPCODE:
        INFO (Context)

void
queue (OpenCL::Context self, OpenCL::Device device, cl_command_queue_properties properties = 0)
	PPCODE:
	NEED_SUCCESS_ARG (cl_command_queue queue, CreateCommandQueue, (self, device, properties, &res));
        XPUSH_CLOBJ ("OpenCL::Queue", queue);

void
user_event (OpenCL::Context self)
	PPCODE:
	NEED_SUCCESS_ARG (cl_event ev, CreateUserEvent, (self, &res));
        XPUSH_CLOBJ ("OpenCL::UserEvent", ev);

void
buffer (OpenCL::Context self, cl_mem_flags flags, size_t len)
	PPCODE:
        if (flags & (CL_MEM_USE_HOST_PTR | CL_MEM_COPY_HOST_PTR))
          croak ("OpenCL::Context::buffer: cannot use/copy host ptr when no data is given, use $context->buffer_sv instead?");
        
        NEED_SUCCESS_ARG (cl_mem mem, CreateBuffer, (self, flags, len, 0, &res));
        XPUSH_CLOBJ ("OpenCL::BufferObj", mem);

void
buffer_sv (OpenCL::Context self, cl_mem_flags flags, SV *data)
	PPCODE:
	STRLEN len;
        char *ptr = SvOK (data) ? SvPVbyte (data, len) : 0;
        if (!(flags & (CL_MEM_USE_HOST_PTR | CL_MEM_COPY_HOST_PTR)))
          croak ("OpenCL::Context::buffer_sv: you have to specify use or copy host ptr when buffer data is given, use $context->buffer instead?");
        NEED_SUCCESS_ARG (cl_mem mem, CreateBuffer, (self, flags, len, ptr, &res));
        XPUSH_CLOBJ ("OpenCL::BufferObj", mem);

#if CL_VERSION_1_2

void
image (OpenCL::Context self, cl_mem_flags flags, cl_channel_order channel_order, cl_channel_type channel_type, cl_mem_object_type type, size_t width, size_t height, size_t depth = 0, size_t array_size = 0, size_t row_pitch = 0, size_t slice_pitch = 0, cl_uint num_mip_level = 0, cl_uint num_samples = 0, SV *data = &PL_sv_undef)
	PPCODE:
	STRLEN len;
        char *ptr = SvOK (data) ? SvPVbyte (data, len) : 0;
        const cl_image_format format = { channel_order, channel_type };
        const cl_image_desc desc = {
          type,
          width, height, depth,
          array_size, row_pitch, slice_pitch,
          num_mip_level, num_samples,
	  type == CL_MEM_OBJECT_IMAGE1D_BUFFER ? (cl_mem)SvCLOBJ ("OpenCL::Context::Image", "data", data, "OpenCL::Buffer") : 0
        };
	NEED_SUCCESS_ARG (cl_mem mem, CreateImage, (self, flags, &format, &desc, ptr, &res));
        char *klass = "OpenCL::Image";
        switch (type)
          {
            case CL_MEM_OBJECT_IMAGE1D_BUFFER:	klass = "OpenCL::Image1DBuffer"; break;
            case CL_MEM_OBJECT_IMAGE1D:		klass = "OpenCL::Image1D";       break;
            case CL_MEM_OBJECT_IMAGE1D_ARRAY:	klass = "OpenCL::Image2DArray";  break;
            case CL_MEM_OBJECT_IMAGE2D:		klass = "OpenCL::Image2D";       break;
            case CL_MEM_OBJECT_IMAGE2D_ARRAY:	klass = "OpenCL::Image2DArray";  break;
            case CL_MEM_OBJECT_IMAGE3D:		klass = "OpenCL::Image3D";       break;
          }
        XPUSH_CLOBJ (klass, mem);

#endif

void
image2d (OpenCL::Context self, cl_mem_flags flags, cl_channel_order channel_order, cl_channel_type channel_type, size_t width, size_t height, size_t row_pitch = 0, SV *data = &PL_sv_undef)
	PPCODE:
	STRLEN len;
        char *ptr = SvOK (data) ? SvPVbyte (data, len) : 0;
        const cl_image_format format = { channel_order, channel_type };
#if PREFER_1_1
	NEED_SUCCESS_ARG (cl_mem mem, CreateImage2D, (self, flags, &format, width, height, row_pitch, ptr, &res));
#else
        const cl_image_desc desc = { CL_MEM_OBJECT_IMAGE2D, width, height, 0, 0, row_pitch, 0, 0, 0, 0 };
	NEED_SUCCESS_ARG (cl_mem mem, CreateImage, (self, flags, &format, &desc, ptr, &res));
#endif
        XPUSH_CLOBJ ("OpenCL::Image2D", mem);

void
image3d (OpenCL::Context self, cl_mem_flags flags, cl_channel_order channel_order, cl_channel_type channel_type, size_t width, size_t height, size_t depth, size_t row_pitch = 0, size_t slice_pitch = 0, SV *data = &PL_sv_undef)
	PPCODE:
	STRLEN len;
        char *ptr = SvOK (data) ? SvPVbyte (data, len) : 0;
        const cl_image_format format = { channel_order, channel_type };
#if PREFER_1_1
	NEED_SUCCESS_ARG (cl_mem mem, CreateImage3D, (self, flags, &format, width, height, depth, row_pitch, slice_pitch, ptr, &res));
#else
        const cl_image_desc desc = { CL_MEM_OBJECT_IMAGE3D, width, height, depth, 0, row_pitch, slice_pitch, 0, 0, 0 };
	NEED_SUCCESS_ARG (cl_mem mem, CreateImage, (self, flags, &format, &desc, ptr, &res));
#endif
        XPUSH_CLOBJ ("OpenCL::Image3D", mem);

#if cl_apple_gl_sharing || cl_khr_gl_sharing

void
gl_buffer (OpenCL::Context self, cl_mem_flags flags, cl_GLuint bufobj)
	PPCODE:
        NEED_SUCCESS_ARG (cl_mem mem, CreateFromGLBuffer, (self, flags, bufobj, &res));
        XPUSH_CLOBJ ("OpenCL::BufferObj", mem);

void
gl_renderbuffer (OpenCL::Context self, cl_mem_flags flags, cl_GLuint renderbuffer)
	PPCODE:
	NEED_SUCCESS_ARG (cl_mem mem, CreateFromGLRenderbuffer, (self, flags, renderbuffer, &res));
        XPUSH_CLOBJ ("OpenCL::Image2D", mem);

#if CL_VERSION_1_2

void
gl_texture (OpenCL::Context self, cl_mem_flags flags, cl_GLenum target, cl_GLint miplevel, cl_GLuint texture)
	ALIAS:
	PPCODE:
	NEED_SUCCESS_ARG (cl_mem mem, CreateFromGLTexture, (self, flags, target, miplevel, texture, &res));
        cl_gl_object_type type;
	NEED_SUCCESS (GetGLObjectInfo, (mem, &type, 0)); // TODO: use target instead?
        char *klass = "OpenCL::Memory";
        switch (type)
          {
            case CL_GL_OBJECT_TEXTURE_BUFFER:	klass = "OpenCL::Image1DBuffer"; break;
            case CL_GL_OBJECT_TEXTURE1D:	klass = "OpenCL::Image1D";       break;
            case CL_GL_OBJECT_TEXTURE1D_ARRAY:	klass = "OpenCL::Image2DArray";  break;
            case CL_GL_OBJECT_TEXTURE2D:	klass = "OpenCL::Image2D";       break;
            case CL_GL_OBJECT_TEXTURE2D_ARRAY:	klass = "OpenCL::Image2DArray";  break;
            case CL_GL_OBJECT_TEXTURE3D:	klass = "OpenCL::Image3D";       break;
          }
        XPUSH_CLOBJ (klass, mem);

#endif

void
gl_texture2d (OpenCL::Context self, cl_mem_flags flags, cl_GLenum target, cl_GLint miplevel, cl_GLuint texture)
	PPCODE:
#if PREFER_1_1
	NEED_SUCCESS_ARG (cl_mem mem, CreateFromGLTexture2D, (self, flags, target, miplevel, texture, &res));
#else
	NEED_SUCCESS_ARG (cl_mem mem, CreateFromGLTexture  , (self, flags, target, miplevel, texture, &res));
#endif
        XPUSH_CLOBJ ("OpenCL::Image2D", mem);

void
gl_texture3d (OpenCL::Context self, cl_mem_flags flags, cl_GLenum target, cl_GLint miplevel, cl_GLuint texture)
	PPCODE:
#if PREFER_1_1
	NEED_SUCCESS_ARG (cl_mem mem, CreateFromGLTexture3D, (self, flags, target, miplevel, texture, &res));
#else
	NEED_SUCCESS_ARG (cl_mem mem, CreateFromGLTexture  , (self, flags, target, miplevel, texture, &res));
#endif
        XPUSH_CLOBJ ("OpenCL::Image3D", mem);

#endif

void
supported_image_formats (OpenCL::Context self, cl_mem_flags flags, cl_mem_object_type image_type)
	PPCODE:
{
	cl_uint count;
        cl_image_format *list;
        int i;
 
	NEED_SUCCESS (GetSupportedImageFormats, (self, flags, image_type, 0, 0, &count));
        Newx (list, count, cl_image_format);
	NEED_SUCCESS (GetSupportedImageFormats, (self, flags, image_type, count, list, 0));

        EXTEND (SP, count);
        for (i = 0; i < count; ++i)
          {
            AV *av = newAV ();
            av_store (av, 1, newSVuv (list [i].image_channel_data_type));
            av_store (av, 0, newSVuv (list [i].image_channel_order));
            PUSHs (sv_2mortal (newRV_noinc ((SV *)av)));
          }
}

void
sampler (OpenCL::Context self, cl_bool normalized_coords, cl_addressing_mode addressing_mode, cl_filter_mode filter_mode)
	PPCODE:
	NEED_SUCCESS_ARG (cl_sampler sampler, CreateSampler, (self, normalized_coords, addressing_mode, filter_mode, &res));
        XPUSH_CLOBJ ("OpenCL::Sampler", sampler);

void
program_with_source (OpenCL::Context self, SV *program)
	PPCODE:
	STRLEN len;
        size_t len2;
        const char *ptr = SvPVbyte (program, len);
        
        len2 = len;
	NEED_SUCCESS_ARG (cl_program prog, CreateProgramWithSource, (self, 1, &ptr, &len2, &res));
        XPUSH_CLOBJ ("OpenCL::Program", prog);

#BEGIN:context

void
reference_count (OpenCL::Context self)
 ALIAS:
 reference_count = CL_CONTEXT_REFERENCE_COUNT
 num_devices = CL_CONTEXT_NUM_DEVICES
 PPCODE:
 cl_uint value [1];
 NEED_SUCCESS (GetContextInfo, (self, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
devices (OpenCL::Context self)
 PPCODE:
 size_t size;
 NEED_SUCCESS (GetContextInfo, (self, CL_CONTEXT_DEVICES,    0,     0, &size));
 cl_device_id *value = tmpbuf (size);
 NEED_SUCCESS (GetContextInfo, (self, CL_CONTEXT_DEVICES, size, value,     0));
 int i, n = size / sizeof (*value);
 EXTEND (SP, n);
 for (i = 0; i < n; ++i)
 {
   PUSH_CLOBJ ("OpenCL::Device", value [i]);
 }

void
properties (OpenCL::Context self)
 PPCODE:
 size_t size;
 NEED_SUCCESS (GetContextInfo, (self, CL_CONTEXT_PROPERTIES,    0,     0, &size));
 cl_context_properties *value = tmpbuf (size);
 NEED_SUCCESS (GetContextInfo, (self, CL_CONTEXT_PROPERTIES, size, value,     0));
 int i, n = size / sizeof (*value);
 EXTEND (SP, n);
 for (i = 0; i < n; ++i)
 PUSHs (sv_2mortal (newSVuv ((UV)value [i])));

#END:context

MODULE = OpenCL		PACKAGE = OpenCL::Queue

void
DESTROY (OpenCL::Queue self)
	CODE:
        clReleaseCommandQueue (self);

void
read_buffer (OpenCL::Queue self, OpenCL::Buffer mem, cl_bool blocking, size_t offset, size_t len, SV *data, ...)
	ALIAS:
	enqueue_read_buffer = 0
	PPCODE:
	cl_event ev = 0;
        EVENT_LIST (6, items - 6);

        SvUPGRADE (data, SVt_PV);
        SvGROW (data, len);
        SvPOK_only (data);
        SvCUR_set (data, len);
        NEED_SUCCESS (EnqueueReadBuffer, (self, mem, blocking, offset, len, SvPVX (data), event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

void
write_buffer (OpenCL::Queue self, OpenCL::Buffer mem, cl_bool blocking, size_t offset, SV *data, ...)
	ALIAS:
	enqueue_write_buffer = 0
	PPCODE:
	cl_event ev = 0;
	STRLEN len;
        char *ptr = SvPVbyte (data, len);
        EVENT_LIST (5, items - 5);

        NEED_SUCCESS (EnqueueWriteBuffer, (self, mem, blocking, offset, len, ptr, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

#if CL_VERSION_1_2

void
fill_buffer (OpenCL::Queue self, OpenCL::Buffer mem, SV *data, size_t offset, size_t size, ...)
	ALIAS:
	enqueue_fill_buffer = 0
	PPCODE:
	cl_event ev = 0;
	STRLEN len;
        char *ptr = SvPVbyte (data, len);
        EVENT_LIST (5, items - 5);

        NEED_SUCCESS (EnqueueFillBuffer, (self, mem, ptr, len, offset, size, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

void
fill_image (OpenCL::Queue self, OpenCL::Image img, NV r, NV g, NV b, NV a, size_t x, size_t y, size_t z, size_t width, size_t height, size_t depth, ...)
	ALIAS:
	enqueue_fill_image = 0
	PPCODE:
	cl_event ev = 0;
	STRLEN len;
        const size_t origin [3] = { x, y, z };
        const size_t region [3] = { width, height, depth };
        EVENT_LIST (12, items - 12);

        const cl_float c_f [4] = { r, g, b, a };
        const cl_uint  c_u [4] = { r, g, b, a };
        const cl_int   c_s [4] = { r, g, b, a };
        const void *c_fus [3] = { &c_f, &c_u, &c_s };
        static const char fus [] = { 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 1, 1, 1, 0, 0 };
	cl_image_format format;
        NEED_SUCCESS (GetImageInfo, (img, CL_IMAGE_FORMAT, sizeof (format), &format, 0));
        assert (sizeof (fus) == CL_FLOAT + 1 - CL_SNORM_INT8);
        if (format.image_channel_data_type < CL_SNORM_INT8 || CL_FLOAT < format.image_channel_data_type)
          croak ("enqueue_fill_image: image has unsupported channel type, only opencl 1.2 channel types supported.");

        NEED_SUCCESS (EnqueueFillImage, (self, img, c_fus [fus [format.image_channel_data_type - CL_SNORM_INT8]],
                                         origin, region, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

#endif

void
copy_buffer (OpenCL::Queue self, OpenCL::Buffer src, OpenCL::Buffer dst, size_t src_offset, size_t dst_offset, size_t len, ...)
	ALIAS:
	enqueue_copy_buffer = 0
	PPCODE:
	cl_event ev = 0;
        EVENT_LIST (6, items - 6);

        NEED_SUCCESS (EnqueueCopyBuffer, (self, src, dst, src_offset, dst_offset, len, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

void
read_buffer_rect (OpenCL::Queue self, OpenCL::Memory buf, cl_bool blocking, size_t buf_x, size_t buf_y, size_t buf_z, size_t host_x, size_t host_y, size_t host_z, size_t width, size_t height, size_t depth, size_t buf_row_pitch, size_t buf_slice_pitch, size_t host_row_pitch, size_t host_slice_pitch, SV *data, ...)
	ALIAS:
	enqueue_read_buffer_rect = 0
	PPCODE:
	cl_event ev = 0;
        const size_t buf_origin [3] = { buf_x , buf_y , buf_z  };
        const size_t host_origin[3] = { host_x, host_y, host_z };
        const size_t region[3] = { width, height, depth };
        EVENT_LIST (17, items - 17);

        if (!buf_row_pitch)
          buf_row_pitch = region [0];

        if (!buf_slice_pitch)
          buf_slice_pitch = region [1] * buf_row_pitch;

        if (!host_row_pitch)
          host_row_pitch = region [0];

        if (!host_slice_pitch)
          host_slice_pitch = region [1] * host_row_pitch;

        size_t len = host_row_pitch * host_slice_pitch * region [2];

        SvUPGRADE (data, SVt_PV);
        SvGROW (data, len);
        SvPOK_only (data);
        SvCUR_set (data, len);
        NEED_SUCCESS (EnqueueReadBufferRect, (self, buf, blocking, buf_origin, host_origin, region, buf_row_pitch, buf_slice_pitch, host_row_pitch, host_slice_pitch, SvPVX (data), event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

void
write_buffer_rect (OpenCL::Queue self, OpenCL::Memory buf, cl_bool blocking, size_t buf_x, size_t buf_y, size_t buf_z, size_t host_x, size_t host_y, size_t host_z, size_t width, size_t height, size_t depth, size_t buf_row_pitch, size_t buf_slice_pitch, size_t host_row_pitch, size_t host_slice_pitch, SV *data, ...)
	ALIAS:
	enqueue_write_buffer_rect = 0
	PPCODE:
	cl_event ev = 0;
        const size_t buf_origin [3] = { buf_x , buf_y , buf_z  };
        const size_t host_origin[3] = { host_x, host_y, host_z };
        const size_t region[3] = { width, height, depth };
	STRLEN len;
        char *ptr = SvPVbyte (data, len);
        EVENT_LIST (17, items - 17);

        if (!buf_row_pitch)
          buf_row_pitch = region [0];

        if (!buf_slice_pitch)
          buf_slice_pitch = region [1] * buf_row_pitch;

        if (!host_row_pitch)
          host_row_pitch = region [0];

        if (!host_slice_pitch)
          host_slice_pitch = region [1] * host_row_pitch;

        size_t min_len = host_row_pitch * host_slice_pitch * region [2];

        if (len < min_len)
          croak ("clEnqueueWriteImage: data string is shorter than what would be transferred");

        NEED_SUCCESS (EnqueueWriteBufferRect, (self, buf, blocking, buf_origin, host_origin, region, buf_row_pitch, buf_slice_pitch, host_row_pitch, host_slice_pitch, ptr, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

void
copy_buffer_rect (OpenCL::Queue self, OpenCL::Buffer src, OpenCL::Buffer dst, size_t src_x, size_t src_y, size_t src_z, size_t dst_x, size_t dst_y, size_t dst_z, size_t width, size_t height, size_t depth, size_t src_row_pitch, size_t src_slice_pitch, size_t dst_row_pitch, size_t dst_slice_pitch, ...)
	ALIAS:
	enqueue_copy_buffer_rect = 0
	PPCODE:
	cl_event ev = 0;
        const size_t src_origin[3] = { src_x, src_y, src_z };
        const size_t dst_origin[3] = { dst_x, dst_y, dst_z };
        const size_t region[3] = { width, height, depth };
        EVENT_LIST (16, items - 16);

        NEED_SUCCESS (EnqueueCopyBufferRect, (self, src, dst, src_origin, dst_origin, region, src_row_pitch, src_slice_pitch, dst_row_pitch, dst_slice_pitch, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

void
read_image (OpenCL::Queue self, OpenCL::Image src, cl_bool blocking, size_t src_x, size_t src_y, size_t src_z, size_t width, size_t height, size_t depth, size_t row_pitch, size_t slice_pitch, SV *data, ...)
	ALIAS:
	enqueue_read_image = 0
	PPCODE:
	cl_event ev = 0;
        const size_t src_origin[3] = { src_x, src_y, src_z };
        const size_t region[3] = { width, height, depth };
        EVENT_LIST (12, items - 12);

	if (!row_pitch)
	  row_pitch = img_row_pitch (src);

        if (depth > 1 && !slice_pitch)
          slice_pitch = row_pitch * height;

        size_t len = slice_pitch ? slice_pitch * depth : row_pitch * height;

        SvUPGRADE (data, SVt_PV);
        SvGROW (data, len);
        SvPOK_only (data);
        SvCUR_set (data, len);
        NEED_SUCCESS (EnqueueReadImage, (self, src, blocking, src_origin, region, row_pitch, slice_pitch, SvPVX (data), event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

void
write_image (OpenCL::Queue self, OpenCL::Image dst, cl_bool blocking, size_t dst_x, size_t dst_y, size_t dst_z, size_t width, size_t height, size_t depth, size_t row_pitch, size_t slice_pitch, SV *data, ...)
	ALIAS:
	enqueue_write_image = 0
	PPCODE:
	cl_event ev = 0;
        const size_t dst_origin[3] = { dst_x, dst_y, dst_z };
        const size_t region[3] = { width, height, depth };
	STRLEN len;
        char *ptr = SvPVbyte (data, len);
        EVENT_LIST (12, items - 12);

	if (!row_pitch)
	  row_pitch = img_row_pitch (dst);

        if (depth > 1 && !slice_pitch)
          slice_pitch = row_pitch * height;

        size_t min_len = slice_pitch ? slice_pitch * depth : row_pitch * height;

        if (len < min_len)
          croak ("clEnqueueWriteImage: data string is shorter than what would be transferred");

        NEED_SUCCESS (EnqueueWriteImage, (self, dst, blocking, dst_origin, region, row_pitch, slice_pitch, ptr, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

void
copy_image (OpenCL::Queue self, OpenCL::Image src, OpenCL::Image dst, size_t src_x, size_t src_y, size_t src_z, size_t dst_x, size_t dst_y, size_t dst_z, size_t width, size_t height, size_t depth, ...)
	ALIAS:
	enqueue_copy_image = 0
	PPCODE:
	cl_event ev = 0;
        const size_t src_origin[3] = { src_x, src_y, src_z };
        const size_t dst_origin[3] = { dst_x, dst_y, dst_z };
        const size_t region[3] = { width, height, depth };
        EVENT_LIST (12, items - 12);

        NEED_SUCCESS (EnqueueCopyImage, (self, src, dst, src_origin, dst_origin, region, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

void
copy_image_to_buffer (OpenCL::Queue self, OpenCL::Image src, OpenCL::Buffer dst, size_t src_x, size_t src_y, size_t src_z, size_t width, size_t height, size_t depth, size_t dst_offset, ...)
	ALIAS:
	enqueue_copy_image_to_buffer = 0
	PPCODE:
	cl_event ev = 0;
        const size_t src_origin[3] = { src_x, src_y, src_z };
        const size_t region[3] = { width, height, depth };
        EVENT_LIST (10, items - 10);

        NEED_SUCCESS (EnqueueCopyImageToBuffer, (self, src, dst, src_origin, region, dst_offset, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

void
copy_buffer_to_image (OpenCL::Queue self, OpenCL::Buffer src, OpenCL::Image dst, size_t src_offset, size_t dst_x, size_t dst_y, size_t dst_z, size_t width, size_t height, size_t depth, ...)
	ALIAS:
	enqueue_copy_buffer_to_image = 0
	PPCODE:
	cl_event ev = 0;
        const size_t dst_origin[3] = { dst_x, dst_y, dst_z };
        const size_t region[3] = { width, height, depth };
        EVENT_LIST (10, items - 10);

        NEED_SUCCESS (EnqueueCopyBufferToImage, (self, src, dst, src_offset, dst_origin, region, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

void
task (OpenCL::Queue self, OpenCL::Kernel kernel, ...)
	ALIAS:
	enqueue_task = 0
	PPCODE:
	cl_event ev = 0;
        EVENT_LIST (2, items - 2);

        NEED_SUCCESS (EnqueueTask, (self, kernel, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

void
nd_range_kernel (OpenCL::Queue self, OpenCL::Kernel kernel, SV *global_work_offset, SV *global_work_size, SV *local_work_size = &PL_sv_undef, ...)
	ALIAS:
	enqueue_nd_range_kernel = 0
	PPCODE:
	cl_event ev = 0;
        size_t *gwo = 0, *gws, *lws = 0;
        int gws_len;
        size_t *lists;
        int i;
        EVENT_LIST (5, items - 5);

        if (!SvROK (global_work_size) || SvTYPE (SvRV (global_work_size)) != SVt_PVAV)
          croak ("clEnqueueNDRangeKernel: global_work_size must be an array reference");

        gws_len = AvFILLp (SvRV (global_work_size)) + 1;

        lists = tmpbuf (sizeof (size_t) * 3 * gws_len);

        gws = lists + gws_len * 0;
        for (i = 0; i < gws_len; ++i)
          gws [i] = SvIV (AvARRAY (SvRV (global_work_size))[i]);

        if (SvOK (global_work_offset))
          {
            if (!SvROK (global_work_offset) || SvTYPE (SvRV (global_work_offset)) != SVt_PVAV)
              croak ("clEnqueueNDRangeKernel: global_work_offset must be undef or an array reference");

            if (AvFILLp (SvRV (global_work_size)) + 1 != gws_len)
              croak ("clEnqueueNDRangeKernel: global_work_offset must be undef or an array of same size as global_work_size");

            gwo = lists + gws_len * 1;
            for (i = 0; i < gws_len; ++i)
              gwo [i] = SvIV (AvARRAY (SvRV (global_work_offset))[i]);
          }

        if (SvOK (local_work_size))
          {
            if ((SvOK (local_work_size) && !SvROK (local_work_size)) || SvTYPE (SvRV (local_work_size)) != SVt_PVAV)
              croak ("clEnqueueNDRangeKernel: global_work_size must be undef or an array reference");

            if (AvFILLp (SvRV (local_work_size)) + 1 != gws_len)
              croak ("clEnqueueNDRangeKernel: local_work_local must be undef or an array of same size as global_work_size");

            lws = lists + gws_len * 2;
            for (i = 0; i < gws_len; ++i)
              lws [i] = SvIV (AvARRAY (SvRV (local_work_size))[i]);
          }

        NEED_SUCCESS (EnqueueNDRangeKernel, (self, kernel, gws_len, gwo, gws, lws, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

#if cl_apple_gl_sharing || cl_khr_gl_sharing

void
acquire_gl_objects (OpenCL::Queue self, SV *objects, ...)
	ALIAS:
	enqueue_acquire_gl_objects = 0
        ALIAS:
        enqueue_release_gl_objects = 1
	PPCODE:
        if (!SvROK (objects) || SvTYPE (SvRV (objects)) != SVt_PVAV)
          croak ("OpenCL::Queue::enqueue_acquire/release_gl_objects argument 'objects' must be an arrayref with memory objects, in call");

	cl_event ev = 0;
        EVENT_LIST (2, items - 2);
        AV *av = (AV *)SvRV (objects);
        cl_uint num_objects = av_len (av) + 1;
        cl_mem *object_list = tmpbuf (sizeof (cl_mem) * num_objects);
        int i;

        for (i = num_objects; i--; )
          object_list [i] = SvCLOBJ ("OpenCL::Queue::enqueue_acquire/release_gl_objects", "objects", *av_fetch (av, i, 0), "OpenCL::Memory");

        if (ix)
          NEED_SUCCESS (EnqueueReleaseGLObjects, (self, num_objects, object_list, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));
        else
          NEED_SUCCESS (EnqueueAcquireGLObjects, (self, num_objects, object_list, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

#endif

void
wait_for_events (OpenCL::Queue self, ...)
	ALIAS:
	enqueue_wait_for_events = 0
	CODE:
        EVENT_LIST (1, items - 1);
#if PREFER_1_1
        NEED_SUCCESS (EnqueueWaitForEvents, (self, event_list_count, event_list_ptr));
#else
        NEED_SUCCESS (EnqueueBarrierWithWaitList, (self, event_list_count, event_list_ptr, 0));
#endif

void
marker (OpenCL::Queue self, ...)
	ALIAS:
	enqueue_marker = 0
	PPCODE:
	cl_event ev = 0;
        EVENT_LIST (1, items - 1);
#if PREFER_1_1
	if (!event_list_count)
          NEED_SUCCESS (EnqueueMarker, (self, GIMME_V != G_VOID ? &ev : 0));
        else
#if CL_VERSION_1_2
          NEED_SUCCESS (EnqueueMarkerWithWaitList, (self, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));
#else
          {
            NEED_SUCCESS (EnqueueWaitForEvents, (self, event_list_count, event_list_ptr)); // also a barrier
            NEED_SUCCESS (EnqueueMarker, (self, GIMME_V != G_VOID ? &ev : 0));
          }
#endif
#else
        NEED_SUCCESS (EnqueueMarkerWithWaitList, (self, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));
#endif
        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

void
barrier (OpenCL::Queue self, ...)
	ALIAS:
	enqueue_barrier = 0
	PPCODE:
	cl_event ev = 0;
        EVENT_LIST (1, items - 1);
#if PREFER_1_1
        if (!event_list_count && GIMME_V == G_VOID)
          NEED_SUCCESS (EnqueueBarrier, (self));
        else
#if CL_VERSION_1_2
          NEED_SUCCESS (EnqueueBarrierWithWaitList, (self, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));
#else
          {
            if (event_list_count)
              NEED_SUCCESS (EnqueueWaitForEvents, (self, event_list_count, event_list_ptr));

            if (GIMME_V != G_VOID)
              NEED_SUCCESS (EnqueueMarker, (self, &ev));
          }
#endif
#else
        NEED_SUCCESS (EnqueueBarrierWithWaitList, (self, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));
#endif
        if (ev)
          XPUSH_CLOBJ ("OpenCL::Event", ev);

void
flush (OpenCL::Queue self)
	CODE:
        NEED_SUCCESS (Flush, (self));

void
finish (OpenCL::Queue self)
	CODE:
        NEED_SUCCESS (Finish, (self));

void
info (OpenCL::Queue self, cl_command_queue_info name)
	PPCODE:
        INFO (CommandQueue)

#BEGIN:command_queue

void
context (OpenCL::Queue self)
 PPCODE:
 cl_context value [1];
 NEED_SUCCESS (GetCommandQueueInfo, (self, CL_QUEUE_CONTEXT, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 {
   NEED_SUCCESS (RetainContext, (value [i]));
   PUSH_CLOBJ ("OpenCL::Context", value [i]);
 }

void
device (OpenCL::Queue self)
 PPCODE:
 cl_device_id value [1];
 NEED_SUCCESS (GetCommandQueueInfo, (self, CL_QUEUE_DEVICE, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 {
   PUSH_CLOBJ ("OpenCL::Device", value [i]);
 }

void
reference_count (OpenCL::Queue self)
 PPCODE:
 cl_uint value [1];
 NEED_SUCCESS (GetCommandQueueInfo, (self, CL_QUEUE_REFERENCE_COUNT, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
properties (OpenCL::Queue self)
 PPCODE:
 cl_command_queue_properties value [1];
 NEED_SUCCESS (GetCommandQueueInfo, (self, CL_QUEUE_PROPERTIES, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSViv (value [i])));

#END:command_queue

MODULE = OpenCL		PACKAGE = OpenCL::Memory

void
DESTROY (OpenCL::Memory self)
	CODE:
        clReleaseMemObject (self);

void
info (OpenCL::Memory self, cl_mem_info name)
	PPCODE:
        INFO (MemObject)

#BEGIN:mem

void
type (OpenCL::Memory self)
 PPCODE:
 cl_mem_object_type value [1];
 NEED_SUCCESS (GetMemObjectInfo, (self, CL_MEM_TYPE, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSViv (value [i])));

void
flags (OpenCL::Memory self)
 PPCODE:
 cl_mem_flags value [1];
 NEED_SUCCESS (GetMemObjectInfo, (self, CL_MEM_FLAGS, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSViv (value [i])));

void
size (OpenCL::Memory self)
 ALIAS:
 size = CL_MEM_SIZE
 offset = CL_MEM_OFFSET
 PPCODE:
 size_t value [1];
 NEED_SUCCESS (GetMemObjectInfo, (self, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
host_ptr (OpenCL::Memory self)
 PPCODE:
 void * value [1];
 NEED_SUCCESS (GetMemObjectInfo, (self, CL_MEM_HOST_PTR, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv ((IV)(intptr_t)value [i])));

void
map_count (OpenCL::Memory self)
 ALIAS:
 map_count = CL_MEM_MAP_COUNT
 reference_count = CL_MEM_REFERENCE_COUNT
 PPCODE:
 cl_uint value [1];
 NEED_SUCCESS (GetMemObjectInfo, (self, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
context (OpenCL::Memory self)
 PPCODE:
 cl_context value [1];
 NEED_SUCCESS (GetMemObjectInfo, (self, CL_MEM_CONTEXT, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 {
   NEED_SUCCESS (RetainContext, (value [i]));
   PUSH_CLOBJ ("OpenCL::Context", value [i]);
 }

void
associated_memobject (OpenCL::Memory self)
 PPCODE:
 cl_mem value [1];
 NEED_SUCCESS (GetMemObjectInfo, (self, CL_MEM_ASSOCIATED_MEMOBJECT, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 {
   NEED_SUCCESS (RetainMemObject, (value [i]));
   PUSH_CLOBJ ("OpenCL::Memory", value [i]);
 }

#END:mem

#if cl_apple_gl_sharing || cl_khr_gl_sharing

void
gl_object_info (OpenCL::Memory self)
        PPCODE:
        cl_gl_object_type type;
        cl_GLuint name;
        NEED_SUCCESS (GetGLObjectInfo, (self, &type, &name));
        EXTEND (SP, 2);
        PUSHs (sv_2mortal (newSVuv (type)));
        PUSHs (sv_2mortal (newSVuv (name)));

#endif

MODULE = OpenCL		PACKAGE = OpenCL::BufferObj

void
sub_buffer_region (OpenCL::BufferObj self, cl_mem_flags flags, size_t origin, size_t size)
	PPCODE:
        if (flags & (CL_MEM_USE_HOST_PTR | CL_MEM_COPY_HOST_PTR | CL_MEM_ALLOC_HOST_PTR))
          croak ("clCreateSubBuffer: cannot use/copy/alloc host ptr, doesn't make sense, check your flags!");

        cl_buffer_region crdata = { origin, size };
        
        NEED_SUCCESS_ARG (cl_mem mem, CreateSubBuffer, (self, flags, CL_BUFFER_CREATE_TYPE_REGION, &crdata, &res));
        XPUSH_CLOBJ ("OpenCL::Buffer", mem);

MODULE = OpenCL		PACKAGE = OpenCL::Image

void
image_info (OpenCL::Image self, cl_image_info name)
	PPCODE:
        INFO (Image)

void
format (OpenCL::Image self)
	PPCODE:
        cl_image_format format;
	NEED_SUCCESS (GetImageInfo, (self, CL_IMAGE_FORMAT, sizeof (format), &format, 0));
        EXTEND (SP, 2);
        PUSHs (sv_2mortal (newSVuv (format.image_channel_order)));
        PUSHs (sv_2mortal (newSVuv (format.image_channel_data_type)));

#BEGIN:image

void
element_size (OpenCL::Image self)
 ALIAS:
 element_size = CL_IMAGE_ELEMENT_SIZE
 row_pitch = CL_IMAGE_ROW_PITCH
 slice_pitch = CL_IMAGE_SLICE_PITCH
 width = CL_IMAGE_WIDTH
 height = CL_IMAGE_HEIGHT
 depth = CL_IMAGE_DEPTH
 PPCODE:
 size_t value [1];
 NEED_SUCCESS (GetImageInfo, (self, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

#END:image

#if cl_apple_gl_sharing || cl_khr_gl_sharing

#BEGIN:gl_texture

void
target (OpenCL::Image self)
 PPCODE:
 cl_GLenum value [1];
 NEED_SUCCESS (GetGLTextureInfo, (self, CL_GL_TEXTURE_TARGET, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
gl_mipmap_level (OpenCL::Image self)
 PPCODE:
 cl_GLint value [1];
 NEED_SUCCESS (GetGLTextureInfo, (self, CL_GL_MIPMAP_LEVEL, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSViv (value [i])));

#END:gl_texture

#endif

MODULE = OpenCL		PACKAGE = OpenCL::Sampler

void
DESTROY (OpenCL::Sampler self)
	CODE:
        clReleaseSampler (self);

void
info (OpenCL::Sampler self, cl_sampler_info name)
	PPCODE:
        INFO (Sampler)

#BEGIN:sampler

void
reference_count (OpenCL::Sampler self)
 PPCODE:
 cl_uint value [1];
 NEED_SUCCESS (GetSamplerInfo, (self, CL_SAMPLER_REFERENCE_COUNT, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
context (OpenCL::Sampler self)
 PPCODE:
 cl_context value [1];
 NEED_SUCCESS (GetSamplerInfo, (self, CL_SAMPLER_CONTEXT, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 {
   NEED_SUCCESS (RetainContext, (value [i]));
   PUSH_CLOBJ ("OpenCL::Context", value [i]);
 }

void
normalized_coords (OpenCL::Sampler self)
 PPCODE:
 cl_addressing_mode value [1];
 NEED_SUCCESS (GetSamplerInfo, (self, CL_SAMPLER_NORMALIZED_COORDS, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSViv (value [i])));

void
addressing_mode (OpenCL::Sampler self)
 PPCODE:
 cl_filter_mode value [1];
 NEED_SUCCESS (GetSamplerInfo, (self, CL_SAMPLER_ADDRESSING_MODE, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSViv (value [i])));

void
filter_mode (OpenCL::Sampler self)
 PPCODE:
 cl_bool value [1];
 NEED_SUCCESS (GetSamplerInfo, (self, CL_SAMPLER_FILTER_MODE, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (value [i] ? &PL_sv_yes : &PL_sv_no));

#END:sampler

MODULE = OpenCL		PACKAGE = OpenCL::Program

void
DESTROY (OpenCL::Program self)
	CODE:
        clReleaseProgram (self);

void
build (OpenCL::Program self, SV *devices = &PL_sv_undef, SV *options = &PL_sv_undef, SV *notify = &PL_sv_undef)
	ALIAS:
        build_async = 1
	CODE:
        void (CL_CALLBACK *pfn_notify)(cl_program program, void *user_data) = 0;
        void *user_data = 0;
        cl_uint num_devices = 0;
        cl_device_id *device_list = 0;

        if (SvOK (devices))
	  {
            if (!SvROK (devices) || SvTYPE (SvRV (devices)) != SVt_PVAV)
              croak ("clProgramBuild: devices must be undef or an array of OpenCL::Device objects.");

            AV *av = (AV *)SvRV (devices);
            num_devices = av_len (av) + 1;

            if (num_devices)
              {
                device_list = tmpbuf (sizeof (*device_list) * num_devices);
                int count;
                for (count = 0; count < num_devices; ++count)
                  device_list [count] = SvCLOBJ ("clBuildProgram", "devices", *av_fetch (av, count, 1), "OpenCL::Device");
              }
          }

        if (SvOK (notify))
          {
            NEED_SUCCESS (RetainProgram, (self));
            pfn_notify = eq_program_notify;
            user_data = SvREFCNT_inc (s_get_cv (notify));
          }

	if (ix)
          build_program_async (self, num_devices, device_list, SvPVbyte_nolen (options), user_data);
        else
          NEED_SUCCESS (BuildProgram, (self, num_devices, device_list, SvPVbyte_nolen (options), pfn_notify, user_data));

void
build_info (OpenCL::Program self, OpenCL::Device device, cl_program_build_info name)
	PPCODE:
	size_t size;
	NEED_SUCCESS (GetProgramBuildInfo, (self, device, name, 0, 0, &size));
        SV *sv = sv_2mortal (newSV (size));
        SvUPGRADE (sv, SVt_PV);
        SvPOK_only (sv);
        SvCUR_set (sv, size);
	NEED_SUCCESS (GetProgramBuildInfo, (self, device, name, size, SvPVX (sv), 0));
        XPUSHs (sv);

#BEGIN:program_build

void
build_status (OpenCL::Program self, OpenCL::Device device)
 PPCODE:
 cl_build_status value [1];
 NEED_SUCCESS (GetProgramBuildInfo, (self, device, CL_PROGRAM_BUILD_STATUS, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSViv (value [i])));

void
build_options (OpenCL::Program self, OpenCL::Device device)
 ALIAS:
 build_options = CL_PROGRAM_BUILD_OPTIONS
 build_log = CL_PROGRAM_BUILD_LOG
 PPCODE:
 size_t size;
 NEED_SUCCESS (GetProgramBuildInfo, (self, device, ix,    0,     0, &size));
 char *value = tmpbuf (size);
 NEED_SUCCESS (GetProgramBuildInfo, (self, device, ix, size, value,     0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVpv (value, 0)));

#END:program_build

void
kernel (OpenCL::Program program, SV *function)
	PPCODE:
	NEED_SUCCESS_ARG (cl_kernel kernel, CreateKernel, (program, SvPVbyte_nolen (function), &res));
        XPUSH_CLOBJ ("OpenCL::Kernel", kernel);

void
kernels_in_program (OpenCL::Program program)
	PPCODE:
        cl_uint num_kernels;
	NEED_SUCCESS (CreateKernelsInProgram, (program, 0, 0, &num_kernels));
        cl_kernel *kernels = tmpbuf (sizeof (cl_kernel) * num_kernels);
	NEED_SUCCESS (CreateKernelsInProgram, (program, num_kernels, kernels, 0));

        int i;
        EXTEND (SP, num_kernels);
        for (i = 0; i < num_kernels; ++i)
          PUSH_CLOBJ ("OpenCL::Kernel", kernels [i]);

void
info (OpenCL::Program self, cl_program_info name)
	PPCODE:
        INFO (Program)

void
binaries (OpenCL::Program self)
	PPCODE:
        cl_uint n, i;
        size_t size;

        NEED_SUCCESS (GetProgramInfo, (self, CL_PROGRAM_NUM_DEVICES , sizeof (n)          , &n   , 0));
        if (!n) XSRETURN_EMPTY;

        size_t *sizes = tmpbuf (sizeof (*sizes) * n);
        NEED_SUCCESS (GetProgramInfo, (self, CL_PROGRAM_BINARY_SIZES, sizeof (*sizes) * n, sizes, &size));
        if (size != sizeof (*sizes) * n) XSRETURN_EMPTY;
        unsigned char **ptrs = tmpbuf (sizeof (*ptrs) * n);

        EXTEND (SP, n);
        for (i = 0; i < n; ++i)
          {
            SV *sv = sv_2mortal (newSV (sizes [i]));
            SvUPGRADE (sv, SVt_PV);
            SvPOK_only (sv);
            SvCUR_set (sv, sizes [i]);
            ptrs [i] = (void *)SvPVX (sv);
            PUSHs (sv);
          }

        NEED_SUCCESS (GetProgramInfo, (self, CL_PROGRAM_BINARIES    , sizeof (*ptrs ) * n, ptrs , &size));
        if (size != sizeof (*ptrs) * n) XSRETURN_EMPTY;

#BEGIN:program

void
reference_count (OpenCL::Program self)
 ALIAS:
 reference_count = CL_PROGRAM_REFERENCE_COUNT
 num_devices = CL_PROGRAM_NUM_DEVICES
 PPCODE:
 cl_uint value [1];
 NEED_SUCCESS (GetProgramInfo, (self, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
context (OpenCL::Program self)
 PPCODE:
 cl_context value [1];
 NEED_SUCCESS (GetProgramInfo, (self, CL_PROGRAM_CONTEXT, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 {
   NEED_SUCCESS (RetainContext, (value [i]));
   PUSH_CLOBJ ("OpenCL::Context", value [i]);
 }

void
devices (OpenCL::Program self)
 PPCODE:
 size_t size;
 NEED_SUCCESS (GetProgramInfo, (self, CL_PROGRAM_DEVICES,    0,     0, &size));
 cl_device_id *value = tmpbuf (size);
 NEED_SUCCESS (GetProgramInfo, (self, CL_PROGRAM_DEVICES, size, value,     0));
 int i, n = size / sizeof (*value);
 EXTEND (SP, n);
 for (i = 0; i < n; ++i)
 {
   PUSH_CLOBJ ("OpenCL::Device", value [i]);
 }

void
source (OpenCL::Program self)
 PPCODE:
 size_t size;
 NEED_SUCCESS (GetProgramInfo, (self, CL_PROGRAM_SOURCE,    0,     0, &size));
 char *value = tmpbuf (size);
 NEED_SUCCESS (GetProgramInfo, (self, CL_PROGRAM_SOURCE, size, value,     0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVpv (value, 0)));

void
binary_sizes (OpenCL::Program self)
 PPCODE:
 size_t size;
 NEED_SUCCESS (GetProgramInfo, (self, CL_PROGRAM_BINARY_SIZES,    0,     0, &size));
 size_t *value = tmpbuf (size);
 NEED_SUCCESS (GetProgramInfo, (self, CL_PROGRAM_BINARY_SIZES, size, value,     0));
 int i, n = size / sizeof (*value);
 EXTEND (SP, n);
 for (i = 0; i < n; ++i)
 PUSHs (sv_2mortal (newSVuv (value [i])));

#END:program

MODULE = OpenCL		PACKAGE = OpenCL::Kernel

void
DESTROY (OpenCL::Kernel self)
	CODE:
        clReleaseKernel (self);

void
setf (OpenCL::Kernel self, const char *format, ...)
	CODE:
        int i;
        for (i = 2; ; ++i)
          {
            while (*format == ' ')
              ++format;

            char type = *format++;

            if (!type)
              break;

            if (i >= items)
              croak ("OpenCL::Kernel::setf format string too long (not enough arguments)");

            SV *sv = ST (i);

            union
            {
              cl_char    cc; cl_uchar   cC; cl_short   cs; cl_ushort  cS;
              cl_int     ci; cl_uint    cI; cl_long    cl; cl_ulong   cL;
              cl_half    ch; cl_float   cf; cl_double  cd;
              cl_mem     cm;
              cl_sampler ca;
              size_t     cz;
              cl_event   ce;
            } arg;
            size_t size;

            switch (type)
              {
                case 'c': arg.cc = SvIV (sv); size = sizeof (arg.cc); break;
                case 'C': arg.cC = SvUV (sv); size = sizeof (arg.cC); break;
                case 's': arg.cs = SvIV (sv); size = sizeof (arg.cs); break;
                case 'S': arg.cS = SvUV (sv); size = sizeof (arg.cS); break;
                case 'i': arg.ci = SvIV (sv); size = sizeof (arg.ci); break;
                case 'I': arg.cI = SvUV (sv); size = sizeof (arg.cI); break;
                case 'l': arg.cl = SvIV (sv); size = sizeof (arg.cl); break;
                case 'L': arg.cL = SvUV (sv); size = sizeof (arg.cL); break;

                case 'h': arg.ch = SvUV (sv); size = sizeof (arg.ch); break;
                case 'f': arg.cf = SvNV (sv); size = sizeof (arg.cf); break;
                case 'd': arg.cd = SvNV (sv); size = sizeof (arg.cd); break;
                case 'z': arg.cz = SvUV (sv); size = sizeof (arg.cz); break;

                case 'm': arg.cm = SvCLOBJ ("OpenCL::Kernel::setf", "m", sv, "OpenCL::Memory" ); size = sizeof (arg.cm); break;
                case 'a': arg.ca = SvCLOBJ ("OpenCL::Kernel::setf", "a", sv, "OpenCL::Sampler"); size = sizeof (arg.ca); break;
                case 'e': arg.ca = SvCLOBJ ("OpenCL::Kernel::setf", "e", sv, "OpenCL::Event"  ); size = sizeof (arg.ce); break;

                default:
                  croak ("OpenCL::Kernel::setf format character '%c' not supported", type);
              }

            clSetKernelArg (self, i - 2, size, &arg);
          }

        if (i != items)
          croak ("OpenCL::Kernel::setf format string too short (too many arguments)");

void
set_char (OpenCL::Kernel self, cl_uint idx, cl_char value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_uchar (OpenCL::Kernel self, cl_uint idx, cl_uchar value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_short (OpenCL::Kernel self, cl_uint idx, cl_short value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_ushort (OpenCL::Kernel self, cl_uint idx, cl_ushort value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_int (OpenCL::Kernel self, cl_uint idx, cl_int value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_uint (OpenCL::Kernel self, cl_uint idx, cl_uint value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_long (OpenCL::Kernel self, cl_uint idx, cl_long value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_ulong (OpenCL::Kernel self, cl_uint idx, cl_ulong value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_half (OpenCL::Kernel self, cl_uint idx, cl_half value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_float (OpenCL::Kernel self, cl_uint idx, cl_float value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_double (OpenCL::Kernel self, cl_uint idx, cl_double value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_memory (OpenCL::Kernel self, cl_uint idx, OpenCL::Memory_ornull value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_buffer (OpenCL::Kernel self, cl_uint idx, OpenCL::Buffer_ornull value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_image (OpenCL::Kernel self, cl_uint idx, OpenCL::Image_ornull value)
	ALIAS:
        set_image2d = 0
        set_image3d = 0
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_sampler (OpenCL::Kernel self, cl_uint idx, OpenCL::Sampler value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_local (OpenCL::Kernel self, cl_uint idx, size_t size)
	CODE:
        clSetKernelArg (self, idx, size, 0);

void
set_event (OpenCL::Kernel self, cl_uint idx, OpenCL::Event value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
info (OpenCL::Kernel self, cl_kernel_info name)
	PPCODE:
        INFO (Kernel)

#BEGIN:kernel

void
function_name (OpenCL::Kernel self)
 PPCODE:
 size_t size;
 NEED_SUCCESS (GetKernelInfo, (self, CL_KERNEL_FUNCTION_NAME,    0,     0, &size));
 char *value = tmpbuf (size);
 NEED_SUCCESS (GetKernelInfo, (self, CL_KERNEL_FUNCTION_NAME, size, value,     0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVpv (value, 0)));

void
num_args (OpenCL::Kernel self)
 ALIAS:
 num_args = CL_KERNEL_NUM_ARGS
 reference_count = CL_KERNEL_REFERENCE_COUNT
 PPCODE:
 cl_uint value [1];
 NEED_SUCCESS (GetKernelInfo, (self, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
context (OpenCL::Kernel self)
 PPCODE:
 cl_context value [1];
 NEED_SUCCESS (GetKernelInfo, (self, CL_KERNEL_CONTEXT, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 {
   NEED_SUCCESS (RetainContext, (value [i]));
   PUSH_CLOBJ ("OpenCL::Context", value [i]);
 }

void
program (OpenCL::Kernel self)
 PPCODE:
 cl_program value [1];
 NEED_SUCCESS (GetKernelInfo, (self, CL_KERNEL_PROGRAM, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 {
   NEED_SUCCESS (RetainProgram, (value [i]));
   PUSH_CLOBJ ("OpenCL::Program", value [i]);
 }

#END:kernel

void
work_group_info (OpenCL::Kernel self, OpenCL::Device device, cl_kernel_work_group_info name)
	PPCODE:
	size_t size;
	NEED_SUCCESS (GetKernelWorkGroupInfo, (self, device, name, 0, 0, &size));
        SV *sv = sv_2mortal (newSV (size));
        SvUPGRADE (sv, SVt_PV);
        SvPOK_only (sv);
        SvCUR_set (sv, size);
	NEED_SUCCESS (GetKernelWorkGroupInfo, (self, device, name, size, SvPVX (sv), 0));
        XPUSHs (sv);

#BEGIN:kernel_work_group

void
work_group_size (OpenCL::Kernel self, OpenCL::Device device)
 ALIAS:
 work_group_size = CL_KERNEL_WORK_GROUP_SIZE
 preferred_work_group_size_multiple = CL_KERNEL_PREFERRED_WORK_GROUP_SIZE_MULTIPLE
 PPCODE:
 size_t value [1];
 NEED_SUCCESS (GetKernelWorkGroupInfo, (self, device, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
compile_work_group_size (OpenCL::Kernel self, OpenCL::Device device)
 PPCODE:
 size_t size;
 NEED_SUCCESS (GetKernelWorkGroupInfo, (self, device, CL_KERNEL_COMPILE_WORK_GROUP_SIZE,    0,     0, &size));
 size_t *value = tmpbuf (size);
 NEED_SUCCESS (GetKernelWorkGroupInfo, (self, device, CL_KERNEL_COMPILE_WORK_GROUP_SIZE, size, value,     0));
 int i, n = size / sizeof (*value);
 EXTEND (SP, n);
 for (i = 0; i < n; ++i)
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
local_mem_size (OpenCL::Kernel self, OpenCL::Device device)
 ALIAS:
 local_mem_size = CL_KERNEL_LOCAL_MEM_SIZE
 private_mem_size = CL_KERNEL_PRIVATE_MEM_SIZE
 PPCODE:
 cl_ulong value [1];
 NEED_SUCCESS (GetKernelWorkGroupInfo, (self, device, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

#END:kernel_work_group

MODULE = OpenCL		PACKAGE = OpenCL::Event

void
DESTROY (OpenCL::Event self)
	CODE:
        clReleaseEvent (self);

void
wait (OpenCL::Event self)
	CODE:
	clWaitForEvents (1, &self);

void
cb (OpenCL::Event self, cl_int command_exec_callback_type, SV *cb)
	CODE:
        clSetEventCallback (self, command_exec_callback_type, eq_event_notify, SvREFCNT_inc (s_get_cv (cb)));

void
info (OpenCL::Event self, cl_event_info name)
	PPCODE:
        INFO (Event)

#BEGIN:event

void
command_queue (OpenCL::Event self)
 PPCODE:
 cl_command_queue value [1];
 NEED_SUCCESS (GetEventInfo, (self, CL_EVENT_COMMAND_QUEUE, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 {
   NEED_SUCCESS (RetainCommandQueue, (value [i]));
   PUSH_CLOBJ ("OpenCL::Queue", value [i]);
 }

void
command_type (OpenCL::Event self)
 PPCODE:
 cl_command_type value [1];
 NEED_SUCCESS (GetEventInfo, (self, CL_EVENT_COMMAND_TYPE, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
reference_count (OpenCL::Event self)
 ALIAS:
 reference_count = CL_EVENT_REFERENCE_COUNT
 command_execution_status = CL_EVENT_COMMAND_EXECUTION_STATUS
 PPCODE:
 cl_uint value [1];
 NEED_SUCCESS (GetEventInfo, (self, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

void
context (OpenCL::Event self)
 PPCODE:
 cl_context value [1];
 NEED_SUCCESS (GetEventInfo, (self, CL_EVENT_CONTEXT, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 {
   NEED_SUCCESS (RetainContext, (value [i]));
   PUSH_CLOBJ ("OpenCL::Context", value [i]);
 }

#END:event

void
profiling_info (OpenCL::Event self, cl_profiling_info name)
	PPCODE:
        INFO (EventProfiling)

#BEGIN:profiling

void
profiling_command_queued (OpenCL::Event self)
 ALIAS:
 profiling_command_queued = CL_PROFILING_COMMAND_QUEUED
 profiling_command_submit = CL_PROFILING_COMMAND_SUBMIT
 profiling_command_start = CL_PROFILING_COMMAND_START
 profiling_command_end = CL_PROFILING_COMMAND_END
 PPCODE:
 cl_ulong value [1];
 NEED_SUCCESS (GetEventProfilingInfo, (self, ix, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 PUSHs (sv_2mortal (newSVuv (value [i])));

#END:profiling

MODULE = OpenCL		PACKAGE = OpenCL::UserEvent

void
set_status (OpenCL::UserEvent self, cl_int execution_status)
	CODE:
	clSetUserEventStatus (self, execution_status);

