#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <CL/opencl.h>

typedef cl_platform_id       OpenCL__Platform;
typedef cl_device_id         OpenCL__Device;
typedef cl_context           OpenCL__Context;
typedef cl_command_queue     OpenCL__Queue;

static const struct {
  IV iv;
  const char *name;
} cl_error[] = {
#define def_error(name) { (IV)CL_ ## name, # name },
#include "invalid.h"
};

static const char *
clstrerror (cl_int res)
{
  int i;
  static char numbuf [32];

  for (i = sizeof (cl_error) / sizeof (cl_error [0]); i--; )
    if (cl_error [i].iv == res)
      return cl_error [i].name;

  snprintf (numbuf, sizeof (numbuf), "ERROR(%d)", res);

  return numbuf;
}

#define FAIL(name,res) \
  croak (# name ": %s", clstrerror (res));

#define NEED_SUCCESS(name,args) \
  do { \
    cl_int res = name args; \
    \
    if (res) \
      FAIL (name, res); \
  } while (0)

MODULE = OpenCL		PACKAGE = OpenCL

BOOT:
{
        HV *stash = gv_stashpv ("OpenCL", 1);
        static const struct {
          const char *name;
          IV iv;
        } *civ, const_iv[] = {
#define const_iv(name) { # name, (IV)CL_ ## name },
#include "constiv.h"
        };
        for (civ = const_iv + sizeof (const_iv) / sizeof (const_iv [0]); civ > const_iv; civ--)
          newCONSTSUB (stash, (char *)civ[-1].name, newSViv (civ[-1].iv));
}

void
platforms ()
	PPCODE:
{
	cl_platform_id *list;
        cl_uint count;
        int i;

	NEED_SUCCESS (clGetPlatformIDs, (0, 0, &count));
        Newx (list, count, cl_platform_id);
	NEED_SUCCESS (clGetPlatformIDs, (count, list, 0));

        EXTEND (SP, count);
        for (i = 0; i < count; ++i)
          PUSHs (sv_setref_pv (sv_newmortal (), "OpenCL::Platform", list [i]));

        Safefree (list);
}

void
context_from_type_simple (cl_device_type type = CL_DEVICE_TYPE_DEFAULT)
	PPCODE:
{
	cl_int res;
  	cl_context ctx = clCreateContextFromType (0, type, 0, 0, &res);

        if (res)
          FAIL (clCreateContextFromType, res);

        XPUSHs (sv_setref_pv (sv_newmortal (), "OpenCL::Context", ctx));
}

MODULE = OpenCL		PACKAGE = OpenCL::Platform

void
info (OpenCL::Platform this, cl_platform_info name)
	PPCODE:
{
  	size_t size;
        SV *sv;

  	NEED_SUCCESS (clGetPlatformInfo, (this, name, 0, 0, &size));
        sv = sv_2mortal (newSV (size));
        SvUPGRADE (sv, SVt_PV);
        SvPOK_only (sv);
        SvCUR_set (sv, size);
  	NEED_SUCCESS (clGetPlatformInfo, (this, name, size, SvPVX (sv), 0));
        XPUSHs (sv);
}

void
devices (OpenCL::Platform this, cl_device_type type = CL_DEVICE_TYPE_ALL)
	PPCODE:
{
	cl_device_id *list;
        cl_uint count;
        int i;

	NEED_SUCCESS (clGetDeviceIDs, (this, type, 0, 0, &count));
        Newx (list, count, cl_device_id);
	NEED_SUCCESS (clGetDeviceIDs, (this, type, count, list, 0));

        EXTEND (SP, count);
        for (i = 0; i < count; ++i)
          PUSHs (sv_setref_pv (sv_newmortal (), "OpenCL::Device", list [i]));

        Safefree (list);
}

void
context_from_type_simple (OpenCL::Platform this, cl_device_type type = CL_DEVICE_TYPE_DEFAULT)
	PPCODE:
{
	cl_int res;
	cl_context_properties props[] = { CL_CONTEXT_PLATFORM, (cl_context_properties)this, 0 };
  	cl_context ctx = clCreateContextFromType (props, type, 0, 0, &res);

        if (res)
          FAIL (clCreateContextFromType, res);

        XPUSHs (sv_setref_pv (sv_newmortal (), "OpenCL::Context", ctx));
}

MODULE = OpenCL		PACKAGE = OpenCL::Device

void
info (OpenCL::Device this, cl_device_info name)
	PPCODE:
{
  	size_t size;
        SV *sv;

  	NEED_SUCCESS (clGetDeviceInfo, (this, name, 0, 0, &size));
        sv = sv_2mortal (newSV (size));
        SvUPGRADE (sv, SVt_PV);
        SvPOK_only (sv);
        SvCUR_set (sv, size);
  	NEED_SUCCESS (clGetDeviceInfo, (this, name, size, SvPVX (sv), 0));
        XPUSHs (sv);
}

void
context_simple (OpenCL::Device this)
	PPCODE:
{
	cl_int res;
  	cl_context ctx = clCreateContext (0, 1, &this, 0, 0, &res);

        if (res)
          FAIL (clCreateContext, res);

        XPUSHs (sv_setref_pv (sv_newmortal (), "OpenCL::Context", ctx));
}

MODULE = OpenCL		PACKAGE = OpenCL::Context

void
DESTROY (OpenCL::Context context)
	CODE:
        clReleaseContext (context);

void
info (OpenCL::Context this, cl_context_info name)
	PPCODE:
{
  	size_t size;
        SV *sv;

  	NEED_SUCCESS (clGetContextInfo, (this, name, 0, 0, &size));
        sv = sv_2mortal (newSV (size));
        SvUPGRADE (sv, SVt_PV);
        SvPOK_only (sv);
        SvCUR_set (sv, size);
  	NEED_SUCCESS (clGetContextInfo, (this, name, size, SvPVX (sv), 0));
        XPUSHs (sv);
}

void
command_queue_simple (OpenCL::Context this, OpenCL::Device device)
	PPCODE:
{
	cl_int res;
  	cl_command_queue queue = clCreateCommandQueue (this, device, 0, &res);

        if (res)
          FAIL (clCreateCommandQueue, res);

        XPUSHs (sv_setref_pv (sv_newmortal (), "OpenCL::Queue", queue));
}

MODULE = OpenCL		PACKAGE = OpenCL::Queue

void
DESTROY (OpenCL::Queue this)
	CODE:
        clReleaseCommandQueue (this);

void
info (OpenCL::Queue this, cl_command_queue_info name)
	PPCODE:
{
  	size_t size;
        SV *sv;

  	NEED_SUCCESS (clGetCommandQueueInfo, (this, name, 0, 0, &size));
        sv = sv_2mortal (newSV (size));
        SvUPGRADE (sv, SVt_PV);
        SvPOK_only (sv);
        SvCUR_set (sv, size);
  	NEED_SUCCESS (clGetCommandQueueInfo, (this, name, size, SvPVX (sv), 0));
        XPUSHs (sv);
}

