#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <CL/opencl.h>

typedef cl_platform_id       OpenCL__Platform;
typedef cl_device_id         OpenCL__Device;
typedef cl_context           OpenCL__Context;
typedef cl_command_queue     OpenCL__Queue;
typedef cl_mem               OpenCL__Memory;
typedef cl_mem               OpenCL__Buffer;
typedef cl_mem               OpenCL__Image;
typedef cl_mem               OpenCL__Image2D;
typedef cl_mem               OpenCL__Image3D;
typedef cl_mem               OpenCL__Memory_ornull;
typedef cl_mem               OpenCL__Buffer_ornull;
typedef cl_mem               OpenCL__Image_ornull;
typedef cl_mem               OpenCL__Image2D_ornull;
typedef cl_mem               OpenCL__Image3D_ornull;
typedef cl_sampler           OpenCL__Sampler;
typedef cl_program           OpenCL__Program;
typedef cl_kernel            OpenCL__Kernel;
typedef cl_event             OpenCL__Event;
typedef cl_event             OpenCL__UserEvent;

typedef SV *FUTURE;

/*****************************************************************************/

/* up to two temporary buffers */
static void *
tmpbuf (size_t size)
{
  static int idx;
  static void *buf [2];
  static size_t len [2];

  idx ^= 1;

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
  	NEED_SUCCESS (Get ## class ## Info, (this, name, 0, 0, &size)); \
        SV *sv = sv_2mortal (newSV (size)); \
        SvUPGRADE (sv, SVt_PV); \
        SvPOK_only (sv); \
        SvCUR_set (sv, size); \
  	NEED_SUCCESS (Get ## class ## Info, (this, name, size, SvPVX (sv), 0)); \
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
context_from_type (FUTURE properties = 0, cl_device_type type = CL_DEVICE_TYPE_DEFAULT, FUTURE notify = 0)
	PPCODE:
        NEED_SUCCESS_ARG (cl_context ctx, CreateContextFromType, (0, type, 0, 0, &res));
        XPUSH_NEW_OBJ ("OpenCL::Context", ctx);

void
context (FUTURE properties, FUTURE devices, FUTURE notify = 0)
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
info (OpenCL::Platform this, cl_platform_info name)
	PPCODE:
        INFO (Platform)

void
devices (OpenCL::Platform this, cl_device_type type = CL_DEVICE_TYPE_ALL)
	PPCODE:
	cl_device_id *list;
        cl_uint count;
        int i;

	NEED_SUCCESS (GetDeviceIDs, (this, type, 0, 0, &count));
        list = tmpbuf (sizeof (*list) * count);
	NEED_SUCCESS (GetDeviceIDs, (this, type, count, list, 0));

        EXTEND (SP, count);
        for (i = 0; i < count; ++i)
          PUSHs (sv_setref_pv (sv_newmortal (), "OpenCL::Device", list [i]));

void
context (OpenCL::Platform this, FUTURE properties, SV *devices, FUTURE notify = 0)
	PPCODE:
        if (!SvROK (devices) || SvTYPE (SvRV (devices)) != SVt_PVAV)
          croak ("OpenCL::Platform argument 'device' must be an arrayref with device objects, in call");

        AV *av = (AV *)SvRV (devices);
        cl_uint num_devices = av_len (av) + 1;
        cl_device_id *device_list = tmpbuf (sizeof (cl_device_id) * num_devices);
        int i;

        for (i = num_devices; i--; )
          device_list [i] = SvPTROBJ ("clCreateContext", "devices", *av_fetch (av, i, 0), "OpenCL::Device");

  	NEED_SUCCESS_ARG (cl_context ctx, CreateContext, (0, num_devices, device_list, 0, 0, &res));
        XPUSH_NEW_OBJ ("OpenCL::Context", ctx);

void
context_from_type (OpenCL::Platform this, FUTURE properties = 0, cl_device_type type = CL_DEVICE_TYPE_DEFAULT, FUTURE notify = 0)
	PPCODE:
	cl_context_properties props[] = { CL_CONTEXT_PLATFORM, (cl_context_properties)this, 0 };
        NEED_SUCCESS_ARG (cl_context ctx, CreateContextFromType, (props, type, 0, 0, &res));
        XPUSH_NEW_OBJ ("OpenCL::Context", ctx);

MODULE = OpenCL		PACKAGE = OpenCL::Device

void
info (OpenCL::Device this, cl_device_info name)
	PPCODE:
        INFO (Device)

MODULE = OpenCL		PACKAGE = OpenCL::Context

void
DESTROY (OpenCL::Context context)
	CODE:
        clReleaseContext (context);

void
info (OpenCL::Context this, cl_context_info name)
	PPCODE:
        INFO (Context)

void
queue (OpenCL::Context this, OpenCL::Device device, cl_command_queue_properties properties = 0)
	PPCODE:
  	NEED_SUCCESS_ARG (cl_command_queue queue, CreateCommandQueue, (this, device, properties, &res));
        XPUSH_NEW_OBJ ("OpenCL::Queue", queue);

void
user_event (OpenCL::Context this)
	PPCODE:
  	NEED_SUCCESS_ARG (cl_event ev, CreateUserEvent, (this, &res));
        XPUSH_NEW_OBJ ("OpenCL::UserEvent", ev);

void
buffer (OpenCL::Context this, cl_mem_flags flags, size_t len)
	PPCODE:
        if (flags & (CL_MEM_USE_HOST_PTR | CL_MEM_COPY_HOST_PTR))
          croak ("clCreateBuffer: cannot use/copy host ptr when no data is given, use $context->buffer_sv instead?");
        
        NEED_SUCCESS_ARG (cl_mem mem, CreateBuffer, (this, flags, len, 0, &res));
        XPUSH_NEW_OBJ ("OpenCL::Buffer", mem);

void
buffer_sv (OpenCL::Context this, cl_mem_flags flags, SV *data)
	PPCODE:
	STRLEN len;
        char *ptr = SvPVbyte (data, len);
        
        if (!(flags & (CL_MEM_USE_HOST_PTR | CL_MEM_COPY_HOST_PTR)))
          croak ("clCreateBuffer: have to specify use or copy host ptr when buffer data is given, use $context->buffer instead?");
        
        NEED_SUCCESS_ARG (cl_mem mem, CreateBuffer, (this, flags, len, ptr, &res));
        XPUSH_NEW_OBJ ("OpenCL::Buffer", mem);

void
image2d (OpenCL::Context this, cl_mem_flags flags, cl_channel_order channel_order, cl_channel_type channel_type, size_t width, size_t height, size_t row_pitch = 0, SV *data = &PL_sv_undef)
	PPCODE:
	STRLEN len;
        char *ptr = SvPVbyte (data, len);
        const cl_image_format format = { channel_order, channel_type };
  	NEED_SUCCESS_ARG (cl_mem mem, CreateImage2D, (this, flags, &format, width, height, row_pitch, ptr, &res));
        XPUSH_NEW_OBJ ("OpenCL::Image2D", mem);

void
image3d (OpenCL::Context this, cl_mem_flags flags, cl_channel_order channel_order, cl_channel_type channel_type, size_t width, size_t height, size_t depth, size_t row_pitch = 0, size_t slice_pitch = 0, SV *data = &PL_sv_undef)
	PPCODE:
	STRLEN len;
        char *ptr = SvPVbyte (data, len);
        const cl_image_format format = { channel_order, channel_type };
  	NEED_SUCCESS_ARG (cl_mem mem, CreateImage3D, (this, flags, &format, width, height, depth, row_pitch, slice_pitch, ptr, &res));
        XPUSH_NEW_OBJ ("OpenCL::Image3D", mem);

void
supported_image_formats (OpenCL::Context this, cl_mem_flags flags, cl_mem_object_type image_type)
	PPCODE:
{
	cl_uint count;
        cl_image_format *list;
        int i;
 
  	NEED_SUCCESS (GetSupportedImageFormats, (this, flags, image_type, 0, 0, &count));
        Newx (list, count, cl_image_format);
  	NEED_SUCCESS (GetSupportedImageFormats, (this, flags, image_type, count, list, 0));

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
sampler (OpenCL::Context this, cl_bool normalized_coords, cl_addressing_mode addressing_mode, cl_filter_mode filter_mode)
	PPCODE:
  	NEED_SUCCESS_ARG (cl_sampler sampler, CreateSampler, (this, normalized_coords, addressing_mode, filter_mode, &res));
        XPUSH_NEW_OBJ ("OpenCL::Sampler", sampler);

void
program_with_source (OpenCL::Context this, SV *program)
	PPCODE:
	STRLEN len;
        size_t len2;
        const char *ptr = SvPVbyte (program, len);
        
        len2 = len;
  	NEED_SUCCESS_ARG (cl_program prog, CreateProgramWithSource, (this, 1, &ptr, &len2, &res));
        XPUSH_NEW_OBJ ("OpenCL::Program", prog);

MODULE = OpenCL		PACKAGE = OpenCL::Queue

void
DESTROY (OpenCL::Queue this)
	CODE:
        clReleaseCommandQueue (this);

void
info (OpenCL::Queue this, cl_command_queue_info name)
	PPCODE:
        INFO (CommandQueue)

void
enqueue_read_buffer (OpenCL::Queue this, OpenCL::Buffer mem, cl_bool blocking, size_t offset, size_t len, SV *data, ...)
	PPCODE:
	cl_event ev = 0;
        EVENT_LIST (6, items - 6);

        SvUPGRADE (data, SVt_PV);
        SvGROW (data, len);
        SvPOK_only (data);
        SvCUR_set (data, len);
        NEED_SUCCESS (EnqueueReadBuffer, (this, mem, blocking, offset, len, SvPVX (data), event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_write_buffer (OpenCL::Queue this, OpenCL::Buffer mem, cl_bool blocking, size_t offset, SV *data, ...)
	PPCODE:
	cl_event ev = 0;
	STRLEN len;
        char *ptr = SvPVbyte (data, len);
        EVENT_LIST (5, items - 5);

        NEED_SUCCESS (EnqueueReadBuffer, (this, mem, blocking, offset, len, ptr, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_copy_buffer (OpenCL::Queue this, OpenCL::Buffer src, OpenCL::Buffer dst, size_t src_offset, size_t dst_offset, size_t len, ...)
	PPCODE:
	cl_event ev = 0;
        EVENT_LIST (6, items - 6);

        NEED_SUCCESS (EnqueueCopyBuffer, (this, src, dst, src_offset, dst_offset, len, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_read_image (OpenCL::Queue this, OpenCL::Image src, cl_bool blocking, size_t src_x, size_t src_y, size_t src_z, size_t width, size_t height, size_t depth, size_t row_pitch, size_t slice_pitch, SV *data, ...)
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
        NEED_SUCCESS (EnqueueReadImage, (this, src, blocking, src_origin, region, row_pitch, slice_pitch, SvPVX (data), event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_write_image (OpenCL::Queue this, OpenCL::Image dst, cl_bool blocking, size_t dst_x, size_t dst_y, size_t dst_z, size_t width, size_t height, size_t depth, size_t row_pitch, size_t slice_pitch, SV *data, ...)
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

        NEED_SUCCESS (EnqueueWriteImage, (this, dst, blocking, dst_origin, region, row_pitch, slice_pitch, SvPVX (data), event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_copy_buffer_rect (OpenCL::Queue this, OpenCL::Buffer src, OpenCL::Buffer dst, size_t src_x, size_t src_y, size_t src_z, size_t dst_x, size_t dst_y, size_t dst_z, size_t width, size_t height, size_t depth, size_t src_row_pitch, size_t src_slice_pitch, size_t dst_row_pitch, size_t dst_slice_pitch, ...)
	PPCODE:
	cl_event ev = 0;
        const size_t src_origin[3] = { src_x, src_y, src_z };
        const size_t dst_origin[3] = { dst_x, dst_y, dst_z };
        const size_t region[3] = { width, height, depth };
        EVENT_LIST (16, items - 16);

        NEED_SUCCESS (EnqueueCopyBufferRect, (this, src, dst, src_origin, dst_origin, region, src_row_pitch, src_slice_pitch, dst_row_pitch, dst_slice_pitch, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_copy_buffer_to_image (OpenCL::Queue this, OpenCL::Buffer src, OpenCL::Image dst, size_t src_offset, size_t dst_x, size_t dst_y, size_t dst_z, size_t width, size_t height, size_t depth, ...)
	PPCODE:
	cl_event ev = 0;
        const size_t dst_origin[3] = { dst_x, dst_y, dst_z };
        const size_t region[3] = { width, height, depth };
        EVENT_LIST (10, items - 10);

        NEED_SUCCESS (EnqueueCopyBufferToImage, (this, src, dst, src_offset, dst_origin, region, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_copy_image (OpenCL::Queue this, OpenCL::Image src, OpenCL::Image dst, size_t src_x, size_t src_y, size_t src_z, size_t dst_x, size_t dst_y, size_t dst_z, size_t width, size_t height, size_t depth, ...)
	PPCODE:
	cl_event ev = 0;
        const size_t src_origin[3] = { src_x, src_y, src_z };
        const size_t dst_origin[3] = { dst_x, dst_y, dst_z };
        const size_t region[3] = { width, height, depth };
        EVENT_LIST (12, items - 12);

        NEED_SUCCESS (EnqueueCopyImage, (this, src, dst, src_origin, dst_origin, region, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_copy_image_to_buffer (OpenCL::Queue this, OpenCL::Image src, OpenCL::Buffer dst, size_t src_x, size_t src_y, size_t src_z, size_t width, size_t height, size_t depth, size_t dst_offset, ...)
	PPCODE:
	cl_event ev = 0;
        const size_t src_origin[3] = { src_x, src_y, src_z };
        const size_t region[3] = { width, height, depth };
        EVENT_LIST (10, items - 10);

        NEED_SUCCESS (EnqueueCopyImageToBuffer, (this, src, dst, src_origin, region, dst_offset, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_task (OpenCL::Queue this, OpenCL::Kernel kernel, ...)
	PPCODE:
	cl_event ev = 0;
        EVENT_LIST (2, items - 2);

        NEED_SUCCESS (EnqueueTask, (this, kernel, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_nd_range_kernel (OpenCL::Queue this, OpenCL::Kernel kernel, SV *global_work_offset, SV *global_work_size, SV *local_work_size = &PL_sv_undef, ...)
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

        NEED_SUCCESS (EnqueueNDRangeKernel, (this, kernel, gws_len, gwo, gws, lws, event_list_count, event_list_ptr, GIMME_V != G_VOID ? &ev : 0));

        if (ev)
          XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_marker (OpenCL::Queue this)
	PPCODE:
	cl_event ev;
        NEED_SUCCESS (EnqueueMarker, (this, &ev));
        XPUSH_NEW_OBJ ("OpenCL::Event", ev);

void
enqueue_wait_for_events (OpenCL::Queue this, ...)
	CODE:
        EVENT_LIST (1, items - 1);
        NEED_SUCCESS (EnqueueWaitForEvents, (this, event_list_count, event_list_ptr));

void
enqueue_barrier (OpenCL::Queue this)
	CODE:
        NEED_SUCCESS (EnqueueBarrier, (this));

void
flush (OpenCL::Queue this)
	CODE:
        NEED_SUCCESS (Flush, (this));

void
finish (OpenCL::Queue this)
	CODE:
        NEED_SUCCESS (Finish, (this));

MODULE = OpenCL		PACKAGE = OpenCL::Memory

void
DESTROY (OpenCL::Memory this)
	CODE:
        clReleaseMemObject (this);

void
info (OpenCL::Memory this, cl_mem_info name)
	PPCODE:
        INFO (MemObject)

MODULE = OpenCL		PACKAGE = OpenCL::Sampler

void
DESTROY (OpenCL::Sampler this)
	CODE:
        clReleaseSampler (this);

void
info (OpenCL::Sampler this, cl_sampler_info name)
	PPCODE:
        INFO (Sampler)

MODULE = OpenCL		PACKAGE = OpenCL::Program

void
DESTROY (OpenCL::Program this)
	CODE:
        clReleaseProgram (this);

void
info (OpenCL::Program this, cl_program_info name)
	PPCODE:
        INFO (Program)

void
build (OpenCL::Program this, OpenCL::Device device, SV *options = &PL_sv_undef)
	CODE:
        NEED_SUCCESS (BuildProgram, (this, 1, &device, SvPVbyte_nolen (options), 0, 0));

void
build_info (OpenCL::Program this, OpenCL::Device device, cl_program_build_info name)
	PPCODE:
  	size_t size;
  	NEED_SUCCESS (GetProgramBuildInfo, (this, device, name, 0, 0, &size));
        SV *sv = sv_2mortal (newSV (size));
        SvUPGRADE (sv, SVt_PV);
        SvPOK_only (sv);
        SvCUR_set (sv, size);
  	NEED_SUCCESS (GetProgramBuildInfo, (this, device, name, size, SvPVX (sv), 0));
        XPUSHs (sv);

void
kernel (OpenCL::Program program, SV *function)
	PPCODE:
  	NEED_SUCCESS_ARG (cl_kernel kernel, CreateKernel, (program, SvPVbyte_nolen (function), &res));
        XPUSH_NEW_OBJ ("OpenCL::Kernel", kernel);

MODULE = OpenCL		PACKAGE = OpenCL::Kernel

void
DESTROY (OpenCL::Kernel this)
	CODE:
        clReleaseKernel (this);

void
info (OpenCL::Kernel this, cl_kernel_info name)
	PPCODE:
        INFO (Kernel)

void
set_char (OpenCL::Kernel this, cl_uint idx, cl_char value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_uchar (OpenCL::Kernel this, cl_uint idx, cl_uchar value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_short (OpenCL::Kernel this, cl_uint idx, cl_short value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_ushort (OpenCL::Kernel this, cl_uint idx, cl_ushort value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_int (OpenCL::Kernel this, cl_uint idx, cl_int value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_uint (OpenCL::Kernel this, cl_uint idx, cl_uint value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_long (OpenCL::Kernel this, cl_uint idx, cl_long value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_ulong (OpenCL::Kernel this, cl_uint idx, cl_ulong value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_half (OpenCL::Kernel this, cl_uint idx, cl_half value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_float (OpenCL::Kernel this, cl_uint idx, cl_float value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_double (OpenCL::Kernel this, cl_uint idx, cl_double value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_memory (OpenCL::Kernel this, cl_uint idx, OpenCL::Memory_ornull value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_buffer (OpenCL::Kernel this, cl_uint idx, OpenCL::Buffer_ornull value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_image2d (OpenCL::Kernel this, cl_uint idx, OpenCL::Image2D_ornull value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_image3d (OpenCL::Kernel this, cl_uint idx, OpenCL::Image3D_ornull value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_sampler (OpenCL::Kernel this, cl_uint idx, OpenCL::Sampler value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

void
set_event (OpenCL::Kernel this, cl_uint idx, OpenCL::Event value)
	CODE:
        clSetKernelArg (this, idx, sizeof (value), &value);

MODULE = OpenCL		PACKAGE = OpenCL::Event

void
DESTROY (OpenCL::Event this)
	CODE:
        clReleaseEvent (this);

void
info (OpenCL::Event this, cl_event_info name)
	PPCODE:
        INFO (Event)

void
wait (OpenCL::Event this)
	CODE:
	clWaitForEvents (1, &this);

MODULE = OpenCL		PACKAGE = OpenCL::UserEvent

void
set_status (OpenCL::UserEvent this, cl_int execution_status)
	CODE:
	clSetUserEventStatus (this, execution_status);

