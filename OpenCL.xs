#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#ifdef I_DLFCN
  #include <dlfcn.h>
#endif

#ifdef __APPLE__
  #include <OpenCL/opencl.h>
#else
  #include <CL/opencl.h>
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

  idx = ++idx % buffers;

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

#define NEW_MORTAL_OBJ(class,ptr) sv_setref_pv (sv_newmortal (), class, ptr)
#define XPUSH_NEW_OBJ(class,ptr) XPUSHs (NEW_MORTAL_OBJ (class, ptr))

static void *
SvPTROBJ (const char *func, const char *svname, SV *sv, const char *pkg)
{
  if (SvROK (sv) && sv_derived_from (sv, pkg))
    return (void *)SvIV (SvRV (sv));

   croak ("%s: %s is not of type %s", func, svname, pkg);
}

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

static size_t
img_row_pitch (cl_mem img)
{
  size_t res;
  clGetImageInfo (img, CL_IMAGE_ROW_PITCH, sizeof (res), &res, 0);
  return res;
}

static cl_event *
event_list (SV **items, int count)
{
  if (!count)
    return 0;

  cl_event *list = tmpbuf (sizeof (cl_event) * count);

  while (count--)
    list [count] = SvPTROBJ ("clEnqueue", "wait_events", items [count], "OpenCL::Event");

  return list;
}

#define EVENT_LIST(items,count) \
  cl_uint event_list_count = (count); \
  cl_event *event_list_ptr = event_list (&ST (items), event_list_count)

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
}

cl_int
errno ()
	CODE:
        errno = res;

const char *
err2str (cl_int err)

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
          PUSHs (NEW_MORTAL_OBJ ("OpenCL::Platform", list [i]));

void
context_from_type (cl_context_properties *properties = 0, cl_device_type type = CL_DEVICE_TYPE_DEFAULT, FUTURE notify = 0)
	PPCODE:
        NEED_SUCCESS_ARG (cl_context ctx, CreateContextFromType, (properties, type, 0, 0, &res));
        XPUSH_NEW_OBJ ("OpenCL::Context", ctx);

void
context (cl_context_properties *properties = 0, FUTURE devices, FUTURE notify = 0)
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
context (OpenCL::Platform self, cl_context_properties *properties = 0, SV *devices, FUTURE notify = 0)
	PPCODE:
        if (!SvROK (devices) || SvTYPE (SvRV (devices)) != SVt_PVAV)
          croak ("OpenCL::Platform::context argument 'device' must be an arrayref with device objects, in call");

        AV *av = (AV *)SvRV (devices);
        cl_uint num_devices = av_len (av) + 1;
        cl_device_id *device_list = tmpbuf (sizeof (cl_device_id) * num_devices);
        int i;

        for (i = num_devices; i--; )
          device_list [i] = SvPTROBJ ("clCreateContext", "devices", *av_fetch (av, i, 0), "OpenCL::Device");

	NEED_SUCCESS_ARG (cl_context ctx, CreateContext, (properties, num_devices, device_list, 0, 0, &res));
        XPUSH_NEW_OBJ ("OpenCL::Context", ctx);

void
context_from_type (OpenCL::Platform self, SV *properties = 0, cl_device_type type = CL_DEVICE_TYPE_DEFAULT, FUTURE notify = 0)
	PPCODE:
	cl_context_properties extra[] = { CL_CONTEXT_PLATFORM, (cl_context_properties)self };
        cl_context_properties *props = SvCONTEXTPROPERTIES ("OpenCL::Platform::context_from_type", "properties", properties, extra, 2);
        NEED_SUCCESS_ARG (cl_context ctx, CreateContextFromType, (props, type, 0, 0, &res));
        XPUSH_NEW_OBJ ("OpenCL::Context", ctx);

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
 reference_count_ext  = CL_DEVICE_REFERENCE_COUNT_EXT 
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
   PUSHs (NEW_MORTAL_OBJ ("OpenCL::Platform", value [i]));
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
   PUSHs (NEW_MORTAL_OBJ ("OpenCL::Device", value [i]));
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
        XPUSH_NEW_OBJ ("OpenCL::Queue", queue);

void
user_event (OpenCL::Context self)
	PPCODE:
	NEED_SUCCESS_ARG (cl_event ev, CreateUserEvent, (self, &res));
        XPUSH_NEW_OBJ ("OpenCL::UserEvent", ev);

void
buffer (OpenCL::Context self, cl_mem_flags flags, size_t len)
	PPCODE:
        if (flags & (CL_MEM_USE_HOST_PTR | CL_MEM_COPY_HOST_PTR))
          croak ("OpenCL::Context::buffer: cannot use/copy host ptr when no data is given, use $context->buffer_sv instead?");
        
        NEED_SUCCESS_ARG (cl_mem mem, CreateBuffer, (self, flags, len, 0, &res));
        XPUSH_NEW_OBJ ("OpenCL::BufferObj", mem);

void
buffer_sv (OpenCL::Context self, cl_mem_flags flags, SV *data)
	PPCODE:
	STRLEN len;
        char *ptr = SvOK (data) ? SvPVbyte (data, len) : 0;
        if (!(flags & (CL_MEM_USE_HOST_PTR | CL_MEM_COPY_HOST_PTR)))
          croak ("OpenCL::Context::buffer_sv: you have to specify use or copy host ptr when buffer data is given, use $context->buffer instead?");
        NEED_SUCCESS_ARG (cl_mem mem, CreateBuffer, (self, flags, len, ptr, &res));
        XPUSH_NEW_OBJ ("OpenCL::BufferObj", mem);

void
image2d (OpenCL::Context self, cl_mem_flags flags, cl_channel_order channel_order, cl_channel_type channel_type, size_t width, size_t height, size_t row_pitch = 0, SV *data = &PL_sv_undef)
	PPCODE:
	STRLEN len;
        char *ptr = SvOK (data) ? SvPVbyte (data, len) : 0;
        const cl_image_format format = { channel_order, channel_type };
	NEED_SUCCESS_ARG (cl_mem mem, CreateImage2D, (self, flags, &format, width, height, row_pitch, ptr, &res));
        XPUSH_NEW_OBJ ("OpenCL::Image2D", mem);

void
image3d (OpenCL::Context self, cl_mem_flags flags, cl_channel_order channel_order, cl_channel_type channel_type, size_t width, size_t height, size_t depth, size_t row_pitch = 0, size_t slice_pitch = 0, SV *data = &PL_sv_undef)
	PPCODE:
	STRLEN len;
        char *ptr = SvOK (data) ? SvPVbyte (data, len) : 0;
        const cl_image_format format = { channel_order, channel_type };
	NEED_SUCCESS_ARG (cl_mem mem, CreateImage3D, (self, flags, &format, width, height, depth, row_pitch, slice_pitch, ptr, &res));
        XPUSH_NEW_OBJ ("OpenCL::Image3D", mem);

#if cl_apple_gl_sharing || cl_khr_gl_sharing

void
gl_buffer (OpenCL::Context self, cl_mem_flags flags, cl_GLuint bufobj)
	PPCODE:
        NEED_SUCCESS_ARG (cl_mem mem, CreateFromGLBuffer, (self, flags, bufobj, &res));
        XPUSH_NEW_OBJ ("OpenCL::BufferObj", mem);

void
gl_texture2d (OpenCL::Context self, cl_mem_flags flags, cl_GLenum target, cl_GLint miplevel, cl_GLuint texture)
	PPCODE:
	NEED_SUCCESS_ARG (cl_mem mem, CreateFromGLTexture2D, (self, flags, target, miplevel, texture, &res));
        XPUSH_NEW_OBJ ("OpenCL::Image2D", mem);

void
gl_texture3d (OpenCL::Context self, cl_mem_flags flags, cl_GLenum target, cl_GLint miplevel, cl_GLuint texture)
	PPCODE:
	NEED_SUCCESS_ARG (cl_mem mem, CreateFromGLTexture3D, (self, flags, target, miplevel, texture, &res));
        XPUSH_NEW_OBJ ("OpenCL::Image3D", mem);

void
gl_renderbuffer (OpenCL::Context self, cl_mem_flags flags, cl_GLuint renderbuffer)
	PPCODE:
	NEED_SUCCESS_ARG (cl_mem mem, CreateFromGLRenderbuffer, (self, flags, renderbuffer, &res));
        XPUSH_NEW_OBJ ("OpenCL::Image2D", mem);

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
        XPUSH_NEW_OBJ ("OpenCL::Sampler", sampler);

void
program_with_source (OpenCL::Context self, SV *program)
	PPCODE:
	STRLEN len;
        size_t len2;
        const char *ptr = SvPVbyte (program, len);
        
        len2 = len;
	NEED_SUCCESS_ARG (cl_program prog, CreateProgramWithSource, (self, 1, &ptr, &len2, &res));
        XPUSH_NEW_OBJ ("OpenCL::Program", prog);

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
   PUSHs (NEW_MORTAL_OBJ ("OpenCL::Device", value [i]));
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
enqueue_read_buffer (OpenCL::Queue self, OpenCL::Buffer mem, cl_bool blocking, size_t offset, size_t len, SV *data, ...)
	PPCODE:
	cl_event ev = 0;
        EVENT_LIST (6, items - 6);

        SvUPGRADE (data, SVt_PV);
        SvGROW (data, len);
        SvPOK_only (data);
        SvCUR_set (data, len);
        NEED_SUCCESS (EnqueueReadBuffer, (self, mem, blocking, offset, len, SvPVX (data), event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_write_buffer (OpenCL::Queue self, OpenCL::Buffer mem, cl_bool blocking, size_t offset, SV *data, ...)
	PPCODE:
	cl_event ev = 0;
	STRLEN len;
        char *ptr = SvPVbyte (data, len);
        EVENT_LIST (5, items - 5);

        NEED_SUCCESS (EnqueueReadBuffer, (self, mem, blocking, offset, len, ptr, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_copy_buffer (OpenCL::Queue self, OpenCL::Buffer src, OpenCL::Buffer dst, size_t src_offset, size_t dst_offset, size_t len, ...)
	PPCODE:
	cl_event ev = 0;
        EVENT_LIST (6, items - 6);

        NEED_SUCCESS (EnqueueCopyBuffer, (self, src, dst, src_offset, dst_offset, len, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_read_buffer_rect (OpenCL::Queue self, OpenCL::Memory buf, cl_bool blocking, size_t buf_x, size_t buf_y, size_t buf_z, size_t host_x, size_t host_y, size_t host_z, size_t width, size_t height, size_t depth, size_t buf_row_pitch, size_t buf_slice_pitch, size_t host_row_pitch, size_t host_slice_pitch, SV *data, ...)
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
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_write_buffer_rect (OpenCL::Queue self, OpenCL::Memory buf, cl_bool blocking, size_t buf_x, size_t buf_y, size_t buf_z, size_t host_x, size_t host_y, size_t host_z, size_t width, size_t height, size_t depth, size_t buf_row_pitch, size_t buf_slice_pitch, size_t host_row_pitch, size_t host_slice_pitch, SV *data, ...)
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

        NEED_SUCCESS (EnqueueWriteBufferRect, (self, buf, blocking, buf_origin, host_origin, region, buf_row_pitch, buf_slice_pitch, host_row_pitch, host_slice_pitch, SvPVX (data), event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_copy_buffer_rect (OpenCL::Queue self, OpenCL::Buffer src, OpenCL::Buffer dst, size_t src_x, size_t src_y, size_t src_z, size_t dst_x, size_t dst_y, size_t dst_z, size_t width, size_t height, size_t depth, size_t src_row_pitch, size_t src_slice_pitch, size_t dst_row_pitch, size_t dst_slice_pitch, ...)
	PPCODE:
	cl_event ev = 0;
        const size_t src_origin[3] = { src_x, src_y, src_z };
        const size_t dst_origin[3] = { dst_x, dst_y, dst_z };
        const size_t region[3] = { width, height, depth };
        EVENT_LIST (16, items - 16);

        NEED_SUCCESS (EnqueueCopyBufferRect, (self, src, dst, src_origin, dst_origin, region, src_row_pitch, src_slice_pitch, dst_row_pitch, dst_slice_pitch, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_read_image (OpenCL::Queue self, OpenCL::Image src, cl_bool blocking, size_t src_x, size_t src_y, size_t src_z, size_t width, size_t height, size_t depth, size_t row_pitch, size_t slice_pitch, SV *data, ...)
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
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_write_image (OpenCL::Queue self, OpenCL::Image dst, cl_bool blocking, size_t dst_x, size_t dst_y, size_t dst_z, size_t width, size_t height, size_t depth, size_t row_pitch, size_t slice_pitch, SV *data, ...)
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

        NEED_SUCCESS (EnqueueWriteImage, (self, dst, blocking, dst_origin, region, row_pitch, slice_pitch, SvPVX (data), event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_copy_image (OpenCL::Queue self, OpenCL::Image src, OpenCL::Image dst, size_t src_x, size_t src_y, size_t src_z, size_t dst_x, size_t dst_y, size_t dst_z, size_t width, size_t height, size_t depth, ...)
	PPCODE:
	cl_event ev = 0;
        const size_t src_origin[3] = { src_x, src_y, src_z };
        const size_t dst_origin[3] = { dst_x, dst_y, dst_z };
        const size_t region[3] = { width, height, depth };
        EVENT_LIST (12, items - 12);

        NEED_SUCCESS (EnqueueCopyImage, (self, src, dst, src_origin, dst_origin, region, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_copy_image_to_buffer (OpenCL::Queue self, OpenCL::Image src, OpenCL::Buffer dst, size_t src_x, size_t src_y, size_t src_z, size_t width, size_t height, size_t depth, size_t dst_offset, ...)
	PPCODE:
	cl_event ev = 0;
        const size_t src_origin[3] = { src_x, src_y, src_z };
        const size_t region[3] = { width, height, depth };
        EVENT_LIST (10, items - 10);

        NEED_SUCCESS (EnqueueCopyImageToBuffer, (self, src, dst, src_origin, region, dst_offset, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_copy_buffer_to_image (OpenCL::Queue self, OpenCL::Buffer src, OpenCL::Image dst, size_t src_offset, size_t dst_x, size_t dst_y, size_t dst_z, size_t width, size_t height, size_t depth, ...)
	PPCODE:
	cl_event ev = 0;
        const size_t dst_origin[3] = { dst_x, dst_y, dst_z };
        const size_t region[3] = { width, height, depth };
        EVENT_LIST (10, items - 10);

        NEED_SUCCESS (EnqueueCopyBufferToImage, (self, src, dst, src_offset, dst_origin, region, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_task (OpenCL::Queue self, OpenCL::Kernel kernel, ...)
	PPCODE:
	cl_event ev = 0;
        EVENT_LIST (2, items - 2);

        NEED_SUCCESS (EnqueueTask, (self, kernel, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_nd_range_kernel (OpenCL::Queue self, OpenCL::Kernel kernel, SV *global_work_offset, SV *global_work_size, SV *local_work_size = &PL_sv_undef, ...)
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
            if (SvOK (local_work_size) && !SvROK (local_work_size) || SvTYPE (SvRV (local_work_size)) != SVt_PVAV)
              croak ("clEnqueueNDRangeKernel: global_work_size must be undef or an array reference");

            if (AvFILLp (SvRV (local_work_size)) + 1 != gws_len)
              croak ("clEnqueueNDRangeKernel: local_work_local must be undef or an array of same size as global_work_size");

            lws = lists + gws_len * 2;
            for (i = 0; i < gws_len; ++i)
              lws [i] = SvIV (AvARRAY (SvRV (local_work_size))[i]);
          }

        NEED_SUCCESS (EnqueueNDRangeKernel, (self, kernel, gws_len, gwo, gws, lws, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

#if cl_apple_gl_sharing || cl_khr_gl_sharing

void
enqueue_acquire_gl_objects (OpenCL::Queue self, SV *objects, ...)
        ALIAS:
        enqueue_release_gl_objects = 1
	CODE:
        if (!SvROK (objects) || SvTYPE (SvRV (objects)) != SVt_PVAV)
          croak ("OpenCL::Queue::enqueue_acquire/release_gl_objects argument 'objects' must be an arrayref with memory objects, in call");

	cl_event ev = 0;
        EVENT_LIST (2, items - 2);
        AV *av = (AV *)SvRV (objects);
        cl_uint num_objects = av_len (av) + 1;
        cl_mem *object_list = tmpbuf (sizeof (cl_mem) * num_objects);
        int i;

        for (i = num_objects; i--; )
          object_list [i] = SvPTROBJ ("OpenCL::Queue::enqueue_acquire/release_gl_objects", "objects", *av_fetch (av, i, 0), "OpenCL::Memory");

        if (ix)
          NEED_SUCCESS (EnqueueReleaseGLObjects, (self, num_objects, object_list, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));
        else
          NEED_SUCCESS (EnqueueAcquireGLObjects, (self, num_objects, object_list, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

#endif

void
enqueue_marker (OpenCL::Queue self)
	PPCODE:
	cl_event ev;
        NEED_SUCCESS (EnqueueMarker, (self, &ev));
        XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_wait_for_events (OpenCL::Queue self, ...)
	CODE:
        EVENT_LIST (1, items - 1);
        NEED_SUCCESS (EnqueueWaitForEvents, (self, event_list_count, event_list_ptr));

void
enqueue_barrier (OpenCL::Queue self)
	CODE:
        NEED_SUCCESS (EnqueueBarrier, (self));

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
   PUSHs (NEW_MORTAL_OBJ ("OpenCL::Context", value [i]));
 }

void
device (OpenCL::Queue self)
 PPCODE:
 cl_device_id value [1];
 NEED_SUCCESS (GetCommandQueueInfo, (self, CL_QUEUE_DEVICE, sizeof (value), value, 0));
 EXTEND (SP, 1);
 const int i = 0;
 {
   PUSHs (NEW_MORTAL_OBJ ("OpenCL::Device", value [i]));
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
   PUSHs (NEW_MORTAL_OBJ ("OpenCL::Context", value [i]));
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
   PUSHs (NEW_MORTAL_OBJ ("OpenCL::Memory", value [i]));
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
        XPUSH_NEW_OBJ ("OpenCL::Buffer", mem);

MODULE = OpenCL		PACKAGE = OpenCL::Image

void
image_info (OpenCL::Image self, cl_image_info name)
	PPCODE:
        INFO (Image)

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
   PUSHs (NEW_MORTAL_OBJ ("OpenCL::Context", value [i]));
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
build (OpenCL::Program self, OpenCL::Device device, SV *options = &PL_sv_undef)
	CODE:
        NEED_SUCCESS (BuildProgram, (self, 1, &device, SvPVbyte_nolen (options), 0, 0));

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
        XPUSH_NEW_OBJ ("OpenCL::Kernel", kernel);

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
            ptrs [i] = SvPVX (sv);
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
   PUSHs (NEW_MORTAL_OBJ ("OpenCL::Context", value [i]));
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
   PUSHs (NEW_MORTAL_OBJ ("OpenCL::Device", value [i]));
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
set_image2d (OpenCL::Kernel self, cl_uint idx, OpenCL::Image2D_ornull value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_image3d (OpenCL::Kernel self, cl_uint idx, OpenCL::Image3D_ornull value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

void
set_sampler (OpenCL::Kernel self, cl_uint idx, OpenCL::Sampler value)
	CODE:
        clSetKernelArg (self, idx, sizeof (value), &value);

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
   PUSHs (NEW_MORTAL_OBJ ("OpenCL::Context", value [i]));
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
   PUSHs (NEW_MORTAL_OBJ ("OpenCL::Program", value [i]));
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
   PUSHs (NEW_MORTAL_OBJ ("OpenCL::Queue", value [i]));
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
   PUSHs (NEW_MORTAL_OBJ ("OpenCL::Context", value [i]));
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

