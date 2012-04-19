=head1 NAME

OpenCL - Open Computing Language Bindings

=head1 SYNOPSIS

 use OpenCL;

=head1 DESCRIPTION

This is an early release which might be useful, but hasn't seen much testing.

=head2 OpenCL FROM 10000 FEET HEIGHT

Here is a high level overview of OpenCL:

First you need to find one or more OpenCL::Platforms (kind of like
vendors) - usually there is only one.

Each platform gives you access to a number of OpenCL::Device objects, e.g.
your graphics card.

From a platform and some device(s), you create an OpenCL::Context, which is
a very central object in OpenCL: Once you have a context you can create
most other objects:

OpenCL::Program objects, which store source code and, after building for a
specific device ("compiling and linking"), also binary programs. For each
kernel function in a program you can then create an OpenCL::Kernel object
which represents basically a function call with argument values.

OpenCL::Memory objects of various flavours: OpenCL::Buffer objects (flat
memory areas, think arrays or structs) and OpenCL::Image objects (think 2d
or 3d array) for bulk data and input and output for kernels.

OpenCL::Sampler objects, which are kind of like texture filter modes in
OpenGL.

OpenCL::Queue objects - command queues, which allow you to submit memory
reads, writes and copies, as well as kernel calls to your devices. They
also offer a variety of methods to synchronise request execution, for
example with barriers or OpenCL::Event objects.

OpenCL::Event objects are used to signal when something is complete.

=head2 HELPFUL RESOURCES

The OpenCL spec used to develop this module (1.2 spec was available, but
no implementation was available to me :).

   http://www.khronos.org/registry/cl/specs/opencl-1.1.pdf

OpenCL manpages:

   http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/

If you are into UML class diagrams, the following diagram might help - if
not, it will be mildly cobfusing:

   http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/classDiagram.html

Here's a tutorial from AMD (very AMD-centric, too), not sure how useful it
is, but at least it's free of charge:

   http://developer.amd.com/zones/OpenCLZone/courses/Documents/Introduction_to_OpenCL_Programming%20Training_Guide%20%28201005%29.pdf

And here's NVIDIA's OpenCL Best Practises Guide:

   http://developer.download.nvidia.com/compute/cuda/3_2/toolkit/docs/OpenCL_Best_Practices_Guide.pdf

=head1 BASIC WORKFLOW

To get something done, you basically have to do this once (refer to the
examples below for actual code, this is just a high-level description):

Find some platform (e.g. the first one) and some device(s) (e.g. the first
device of the platform), and create a context from those.

Create program objects from your OpenCL source code, then build (compile)
the programs for each device you want to run them on.

Create kernel objects for all kernels you want to use (surprisingly, these
are not device-specific).

Then, to execute stuff, you repeat these steps, possibly resuing or
sharing some buffers:

Create some input and output buffers from your context. Set these as
arguments to your kernel.

Enqueue buffer writes to initialise your input buffers (when not
initialised at creation time).

Enqueue the kernel execution.

Enqueue buffer reads for your output buffer to read results.

=head1 EXAMPLES

=head2 Enumerate all devices and get contexts for them.

Best run this once to get a feel for the platforms and devices in your
system.

   for my $platform (OpenCL::platforms) {
      printf "platform: %s\n", $platform->name;
      printf "extensions: %s\n", $platform->extensions;
      for my $device ($platform->devices) {
         printf "+ device: %s\n", $device->name;
         my $ctx = $platform->context (undef, [$device]);
         # do stuff
      }
   }

=head2 Get a useful context and a command queue.

This is a useful boilerplate for any OpenCL program that only wants to use
one device,

   my ($platform) = OpenCL::platforms; # find first platform
   my ($dev) = $platform->devices;     # find first device of platform
   my $ctx = $platform->context (undef, [$dev]); # create context out of those
   my $queue = $ctx->queue ($dev);     # create a command queue for the device

=head2 Print all supported image formats of a context.

Best run this once for your context, to see whats available and how to
gather information.

   for my $type (OpenCL::MEM_OBJECT_IMAGE2D, OpenCL::MEM_OBJECT_IMAGE3D) {
      print "supported image formats for ", OpenCL::enum2str $type, "\n";
      
      for my $f ($ctx->supported_image_formats (0, $type)) {
         printf "  %-10s %-20s\n", OpenCL::enum2str $f->[0], OpenCL::enum2str $f->[1];
      }
   }

=head2 Create a buffer with some predefined data, read it back synchronously,
then asynchronously.

   my $buf = $ctx->buffer_sv (OpenCL::MEM_COPY_HOST_PTR, "helmut");

   $queue->enqueue_read_buffer ($buf, 1, 1, 3, my $data);
   print "$data\n";

   my $ev = $queue->enqueue_read_buffer ($buf, 0, 1, 3, my $data);
   $ev->wait;
   print "$data\n"; # prints "elm"

=head2 Create and build a program, then create a kernel out of one of its
functions.

   my $src = '
      kernel void
      squareit (global float *input, global float *output)
      {
        $id = get_global_id (0);
        output [id] = input [id] * input [id];
      }
   ';

   my $prog = $ctx->program_with_source ($src);

   # build croaks on compile errors, so catch it and print the compile errors
   eval { $prog->build ($dev); 1 }
      or die $prog->build_log;

   my $kernel = $prog->kernel ("squareit");

=head2 Create some input and output float buffers, then call the
'squareit' kernel on them.

   my $input  = $ctx->buffer_sv (OpenCL::MEM_COPY_HOST_PTR, pack "f*", 1, 2, 3, 4.5);
   my $output = $ctx->buffer (0, OpenCL::SIZEOF_FLOAT * 5);

   # set buffer
   $kernel->set_buffer (0, $input);
   $kernel->set_buffer (1, $output);

   # execute it for all 4 numbers
   $queue->enqueue_nd_range_kernel ($kernel, undef, [4], undef);

   # enqueue a synchronous read
   $queue->enqueue_read_buffer ($output, 1, 0, OpenCL::SIZEOF_FLOAT * 4, my $data);

   # print the results:
   printf "%s\n", join ", ", unpack "f*", $data;

=head2 The same enqueue operations as before, but assuming an out-of-order queue,
showing off barriers.

   # execute it for all 4 numbers
   $queue->enqueue_nd_range_kernel ($kernel, undef, [4], undef);

   # enqueue a barrier to ensure in-order execution
   $queue->enqueue_barrier;

   # enqueue an async read
   $queue->enqueue_read_buffer ($output, 0, 0, OpenCL::SIZEOF_FLOAT * 4, my $data);

   # wait for all requests to finish
   $queue->finish;

=head2 The same enqueue operations as before, but assuming an out-of-order queue,
showing off event objects and wait lists.

   # execute it for all 4 numbers
   my $ev = $queue->enqueue_nd_range_kernel ($kernel, undef, [4], undef);

   # enqueue an async read
   $ev = $queue->enqueue_read_buffer ($output, 0, 0, OpenCL::SIZEOF_FLOAT * 4, my $data, $ev);

   # wait for the last event to complete
   $ev->wait;

=head2 Use the OpenGL module to share a texture between OpenCL and OpenGL and draw some julia
set tunnel effect.

This is quite a long example to get you going.

   use OpenGL ":all";
   use OpenCL;

   # open a window and create a gl texture
   OpenGL::glpOpenWindow width => 256, height => 256;
   my $texid = glGenTextures_p 1;
   glBindTexture GL_TEXTURE_2D, $texid;
   glTexImage2D_c GL_TEXTURE_2D, 0, GL_RGBA8, 256, 256, 0, GL_RGBA, GL_UNSIGNED_BYTE, 0;

   # find and use the first opencl device that let's us get a shared opengl context
   my $platform;
   my $dev;
   my $ctx;

   for (OpenCL::platforms) {
      $platform = $_;
      for ($platform->devices) {
         $dev = $_;
         $ctx = $platform->context ([OpenCL::GLX_DISPLAY_KHR, undef, OpenCL::GL_CONTEXT_KHR, undef], [$dev])
            and last;
      }
   }

   $ctx
      or die "cannot find suitable OpenCL device\n";

   my $queue = $ctx->queue ($dev);

   # now attach an opencl image2d object to the opengl texture
   my $tex = $ctx->gl_texture2d (OpenCL::MEM_WRITE_ONLY, GL_TEXTURE_2D, 0, $texid);

   # now the boring opencl code
   my $src = <<EOF;
   kernel void
   juliatunnel (write_only image2d_t img, float time)
   {
     float2 p = (float2)(get_global_id (0), get_global_id (1)) / 256.f * 2.f - 1.f;

     float2 m = (float2)(1.f, p.y) / fabs (p.x);
     m.x = fabs (fmod (m.x + time * 0.05f, 4.f)) - 2.f;

     float2 z = m;
     float2 c = (float2)(sin (time * 0.05005), cos (time * 0.06001));

     for (int i = 0; i < 25 && dot (z, z) < 4.f; ++i)
       z = (float2)(z.x * z.x - z.y * z.y, 2.f * z.x * z.y) + c;

     float3 colour = (float3)(z.x, z.y, z.x * z.y);
     write_imagef (img, (int2)(get_global_id (0), get_global_id (1)), (float4)(colour * p.x * p.x, 1.));
   }
   EOF
   my $prog = $ctx->program_with_source ($src);
   eval { $prog->build ($dev); 1 }
      or die $prog->build_log ($dev);

   my $kernel = $prog->kernel ("juliatunnel");

   # program compiled, kernel ready, now draw and loop

   for (my $time; ; ++$time) {
      # acquire objects from opengl
      $queue->enqueue_acquire_gl_objects ([$tex]);

      # configure and run our kernel
      $kernel->set_image2d (0, $tex);
      $kernel->set_float   (1, $time);
      $queue->enqueue_nd_range_kernel ($kernel, undef, [256, 256], undef);

      # release objects to opengl again
      $queue->enqueue_release_gl_objects ([$tex]);

      # wait
      $queue->flush;

      # now draw the texture, the defaults should be all right
      glTexParameterf GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST;

      glEnable GL_TEXTURE_2D;
      glBegin GL_QUADS;
         glTexCoord2f 0, 1; glVertex3i -1, -1, -1;
         glTexCoord2f 0, 0; glVertex3i  1, -1, -1;
         glTexCoord2f 1, 0; glVertex3i  1,  1, -1;
         glTexCoord2f 1, 1; glVertex3i -1,  1, -1;
      glEnd;

      glXSwapBuffers;

      select undef, undef, undef, 1/60;
   }

=head1 DOCUMENTATION

=head2 BASIC CONVENTIONS

This is not a one-to-one C-style translation of OpenCL to Perl - instead
I attempted to make the interface as type-safe as possible by introducing
object syntax where it makes sense. There are a number of important
differences between the OpenCL C API and this module:

=over 4

=item * Object lifetime managament is automatic - there is no need
to free objects explicitly (C<clReleaseXXX>), the release function
is called automatically once all Perl references to it go away.

=item * OpenCL uses CamelCase for function names
(e.g. C<clGetPlatformIDs>, C<clGetPlatformInfo>), while this module
uses underscores as word separator and often leaves out prefixes
(C<OpenCL::platforms>, C<< $platform->info >>).

=item * OpenCL often specifies fixed vector function arguments as short
arrays (C<size_t origin[3]>), while this module explicitly expects the
components as separate arguments (C<$orig_x, $orig_y, $orig_z>) in
function calls.

=item * Structures are often specified by flattening out their components
as with short vectors, and returned as arrayrefs.

=item * When enqueuing commands, the wait list is specified by adding
extra arguments to the function - anywhere a C<$wait_events...> argument
is documented this can be any number of event objects.

=item * When enqueuing commands, if the enqueue method is called in void
context, no event is created. In all other contexts an event is returned
by the method.

=item * This module expects all functions to return C<CL_SUCCESS>. If any
other status is returned the function will throw an exception, so you
don't normally have to to any error checking.

=back

=head2 PERL AND OPENCL TYPES

This handy(?) table lists OpenCL types and their perl, PDL and pack/unpack
format equivalents:

   OpenCL    perl   PDL       pack/unpack
   char      IV     -         c
   uchar     IV     byte      C
   short     IV     short     s
   ushort    IV     ushort    S
   int       IV     long?     l
   uint      IV     -         L
   long      IV     longlong  q
   ulong     IV     -         Q
   float     NV     float     f
   half      IV     ushort    S
   double    NV     double    d

=head2 GLX SUPPORT

Due to the sad state that OpenGL support is in in Perl (mostly the OpenGL
module, which has little to no documentation and has little to no support
for glX), this module, as a special extension, treats context creation
properties C<OpenCL::GLX_DISPLAY_KHR> and C<OpenCL::GL_CONTEXT_KHR>
specially: If either or both of these are C<undef>, then the OpenCL
module tries to dynamically resolve C<glXGetCurrentDisplay> and
C<glXGetCurrentContext>, call these functions and use their return values
instead.

For this to work, the OpenGL library must be loaded, a GLX context must
have been created and be made current, and C<dlsym> must be available and
capable of finding the function via C<RTLD_DEFAULT>.

=head2 THE OpenCL PACKAGE

=over 4

=item $int = OpenCL::errno

The last error returned by a function - it's only valid after an error occured
and before calling another OpenCL function.

=item $str = OpenCL::err2str $errval

Comverts an error value into a human readable string.

=item $str = OpenCL::enum2str $enum

Converts most enum values (of parameter names, image format constants,
object types, addressing and filter modes, command types etc.) into a
human readable string. When confronted with some random integer it can be
very helpful to pass it through this function to maybe get some readable
string out of it.

=item @platforms = OpenCL::platforms

Returns all available OpenCL::Platform objects.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetPlatformIDs.html>

=item $ctx = OpenCL::context_from_type $properties, $type = OpenCL::DEVICE_TYPE_DEFAULT, $notify = undef

Tries to create a context from a default device and platform - never worked for me.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateContextFromType.html>

=item OpenCL::wait_for_events $wait_events...

Waits for all events to complete.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clWaitForEvents.html>

=back

=head2 THE OpenCL::Platform CLASS

=over 4

=item @devices = $platform->devices ($type = OpenCL::DEVICE_TYPE_ALL)

Returns a list of matching OpenCL::Device objects.

=item $ctx = $platform->context_from_type ($properties, $type = OpenCL::DEVICE_TYPE_DEFAULT, $notify = undef)

Tries to create a context. Never worked for me, and you need devices explicitly anyway.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateContextFromType.html>

=item $ctx = $platform->context ($properties = undef, @$devices, $notify = undef)

Create a new OpenCL::Context object using the given device object(s)- a
CL_CONTEXT_PLATFORM property is supplied automatically.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateContext.html>

=item $packed_value = $platform->info ($name)

Calls C<clGetPlatformInfo> and returns the packed, raw value - for
strings, this will be the string (possibly including terminating \0), for
other values you probably need to use the correct C<unpack>.

It's best to avoid this method and use one of the following convenience
wrappers.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetPlatformInfo.html>

=for gengetinfo begin platform

=item $string = $platform->profile

Calls C<clGetPlatformInfo> with C<CL_PLATFORM_PROFILE> and returns the result.

=item $string = $platform->version

Calls C<clGetPlatformInfo> with C<CL_PLATFORM_VERSION> and returns the result.

=item $string = $platform->name

Calls C<clGetPlatformInfo> with C<CL_PLATFORM_NAME> and returns the result.

=item $string = $platform->vendor

Calls C<clGetPlatformInfo> with C<CL_PLATFORM_VENDOR> and returns the result.

=item $string = $platform->extensions

Calls C<clGetPlatformInfo> with C<CL_PLATFORM_EXTENSIONS> and returns the result.

=for gengetinfo end platform

=back

=head2 THE OpenCL::Device CLASS

=over 4

=item $packed_value = $device->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetDeviceInfo.html>

=for gengetinfo begin device

=item $device_type = $device->type

Calls C<clGetDeviceInfo> with C<CL_DEVICE_TYPE> and returns the result.

=item $uint = $device->vendor_id

Calls C<clGetDeviceInfo> with C<CL_DEVICE_VENDOR_ID> and returns the result.

=item $uint = $device->max_compute_units

Calls C<clGetDeviceInfo> with C<CL_DEVICE_MAX_COMPUTE_UNITS> and returns the result.

=item $uint = $device->max_work_item_dimensions

Calls C<clGetDeviceInfo> with C<CL_DEVICE_MAX_WORK_ITEM_DIMENSIONS> and returns the result.

=item $int = $device->max_work_group_size

Calls C<clGetDeviceInfo> with C<CL_DEVICE_MAX_WORK_GROUP_SIZE> and returns the result.

=item @ints = $device->max_work_item_sizes

Calls C<clGetDeviceInfo> with C<CL_DEVICE_MAX_WORK_ITEM_SIZES> and returns the result.

=item $uint = $device->preferred_vector_width_char

Calls C<clGetDeviceInfo> with C<CL_DEVICE_PREFERRED_VECTOR_WIDTH_CHAR> and returns the result.

=item $uint = $device->preferred_vector_width_short

Calls C<clGetDeviceInfo> with C<CL_DEVICE_PREFERRED_VECTOR_WIDTH_SHORT> and returns the result.

=item $uint = $device->preferred_vector_width_int

Calls C<clGetDeviceInfo> with C<CL_DEVICE_PREFERRED_VECTOR_WIDTH_INT> and returns the result.

=item $uint = $device->preferred_vector_width_long

Calls C<clGetDeviceInfo> with C<CL_DEVICE_PREFERRED_VECTOR_WIDTH_LONG> and returns the result.

=item $uint = $device->preferred_vector_width_float

Calls C<clGetDeviceInfo> with C<CL_DEVICE_PREFERRED_VECTOR_WIDTH_FLOAT> and returns the result.

=item $uint = $device->preferred_vector_width_double

Calls C<clGetDeviceInfo> with C<CL_DEVICE_PREFERRED_VECTOR_WIDTH_DOUBLE> and returns the result.

=item $uint = $device->max_clock_frequency

Calls C<clGetDeviceInfo> with C<CL_DEVICE_MAX_CLOCK_FREQUENCY> and returns the result.

=item $bitfield = $device->address_bits

Calls C<clGetDeviceInfo> with C<CL_DEVICE_ADDRESS_BITS> and returns the result.

=item $uint = $device->max_read_image_args

Calls C<clGetDeviceInfo> with C<CL_DEVICE_MAX_READ_IMAGE_ARGS> and returns the result.

=item $uint = $device->max_write_image_args

Calls C<clGetDeviceInfo> with C<CL_DEVICE_MAX_WRITE_IMAGE_ARGS> and returns the result.

=item $ulong = $device->max_mem_alloc_size

Calls C<clGetDeviceInfo> with C<CL_DEVICE_MAX_MEM_ALLOC_SIZE> and returns the result.

=item $int = $device->image2d_max_width

Calls C<clGetDeviceInfo> with C<CL_DEVICE_IMAGE2D_MAX_WIDTH> and returns the result.

=item $int = $device->image2d_max_height

Calls C<clGetDeviceInfo> with C<CL_DEVICE_IMAGE2D_MAX_HEIGHT> and returns the result.

=item $int = $device->image3d_max_width

Calls C<clGetDeviceInfo> with C<CL_DEVICE_IMAGE3D_MAX_WIDTH> and returns the result.

=item $int = $device->image3d_max_height

Calls C<clGetDeviceInfo> with C<CL_DEVICE_IMAGE3D_MAX_HEIGHT> and returns the result.

=item $int = $device->image3d_max_depth

Calls C<clGetDeviceInfo> with C<CL_DEVICE_IMAGE3D_MAX_DEPTH> and returns the result.

=item $uint = $device->image_support

Calls C<clGetDeviceInfo> with C<CL_DEVICE_IMAGE_SUPPORT> and returns the result.

=item $int = $device->max_parameter_size

Calls C<clGetDeviceInfo> with C<CL_DEVICE_MAX_PARAMETER_SIZE> and returns the result.

=item $uint = $device->max_samplers

Calls C<clGetDeviceInfo> with C<CL_DEVICE_MAX_SAMPLERS> and returns the result.

=item $uint = $device->mem_base_addr_align

Calls C<clGetDeviceInfo> with C<CL_DEVICE_MEM_BASE_ADDR_ALIGN> and returns the result.

=item $uint = $device->min_data_type_align_size

Calls C<clGetDeviceInfo> with C<CL_DEVICE_MIN_DATA_TYPE_ALIGN_SIZE> and returns the result.

=item $device_fp_config = $device->single_fp_config

Calls C<clGetDeviceInfo> with C<CL_DEVICE_SINGLE_FP_CONFIG> and returns the result.

=item $device_mem_cache_type = $device->global_mem_cache_type

Calls C<clGetDeviceInfo> with C<CL_DEVICE_GLOBAL_MEM_CACHE_TYPE> and returns the result.

=item $uint = $device->global_mem_cacheline_size

Calls C<clGetDeviceInfo> with C<CL_DEVICE_GLOBAL_MEM_CACHELINE_SIZE> and returns the result.

=item $ulong = $device->global_mem_cache_size

Calls C<clGetDeviceInfo> with C<CL_DEVICE_GLOBAL_MEM_CACHE_SIZE> and returns the result.

=item $ulong = $device->global_mem_size

Calls C<clGetDeviceInfo> with C<CL_DEVICE_GLOBAL_MEM_SIZE> and returns the result.

=item $ulong = $device->max_constant_buffer_size

Calls C<clGetDeviceInfo> with C<CL_DEVICE_MAX_CONSTANT_BUFFER_SIZE> and returns the result.

=item $uint = $device->max_constant_args

Calls C<clGetDeviceInfo> with C<CL_DEVICE_MAX_CONSTANT_ARGS> and returns the result.

=item $device_local_mem_type = $device->local_mem_type

Calls C<clGetDeviceInfo> with C<CL_DEVICE_LOCAL_MEM_TYPE> and returns the result.

=item $ulong = $device->local_mem_size

Calls C<clGetDeviceInfo> with C<CL_DEVICE_LOCAL_MEM_SIZE> and returns the result.

=item $boolean = $device->error_correction_support

Calls C<clGetDeviceInfo> with C<CL_DEVICE_ERROR_CORRECTION_SUPPORT> and returns the result.

=item $int = $device->profiling_timer_resolution

Calls C<clGetDeviceInfo> with C<CL_DEVICE_PROFILING_TIMER_RESOLUTION> and returns the result.

=item $boolean = $device->endian_little

Calls C<clGetDeviceInfo> with C<CL_DEVICE_ENDIAN_LITTLE> and returns the result.

=item $boolean = $device->available

Calls C<clGetDeviceInfo> with C<CL_DEVICE_AVAILABLE> and returns the result.

=item $boolean = $device->compiler_available

Calls C<clGetDeviceInfo> with C<CL_DEVICE_COMPILER_AVAILABLE> and returns the result.

=item $device_exec_capabilities = $device->execution_capabilities

Calls C<clGetDeviceInfo> with C<CL_DEVICE_EXECUTION_CAPABILITIES> and returns the result.

=item $command_queue_properties = $device->properties

Calls C<clGetDeviceInfo> with C<CL_DEVICE_QUEUE_PROPERTIES> and returns the result.

=item $ = $device->platform

Calls C<clGetDeviceInfo> with C<CL_DEVICE_PLATFORM> and returns the result.

=item $string = $device->name

Calls C<clGetDeviceInfo> with C<CL_DEVICE_NAME> and returns the result.

=item $string = $device->vendor

Calls C<clGetDeviceInfo> with C<CL_DEVICE_VENDOR> and returns the result.

=item $string = $device->driver_version

Calls C<clGetDeviceInfo> with C<CL_DRIVER_VERSION> and returns the result.

=item $string = $device->profile

Calls C<clGetDeviceInfo> with C<CL_DEVICE_PROFILE> and returns the result.

=item $string = $device->version

Calls C<clGetDeviceInfo> with C<CL_DEVICE_VERSION> and returns the result.

=item $string = $device->extensions

Calls C<clGetDeviceInfo> with C<CL_DEVICE_EXTENSIONS> and returns the result.

=item $uint = $device->preferred_vector_width_half

Calls C<clGetDeviceInfo> with C<CL_DEVICE_PREFERRED_VECTOR_WIDTH_HALF> and returns the result.

=item $uint = $device->native_vector_width_char

Calls C<clGetDeviceInfo> with C<CL_DEVICE_NATIVE_VECTOR_WIDTH_CHAR> and returns the result.

=item $uint = $device->native_vector_width_short

Calls C<clGetDeviceInfo> with C<CL_DEVICE_NATIVE_VECTOR_WIDTH_SHORT> and returns the result.

=item $uint = $device->native_vector_width_int

Calls C<clGetDeviceInfo> with C<CL_DEVICE_NATIVE_VECTOR_WIDTH_INT> and returns the result.

=item $uint = $device->native_vector_width_long

Calls C<clGetDeviceInfo> with C<CL_DEVICE_NATIVE_VECTOR_WIDTH_LONG> and returns the result.

=item $uint = $device->native_vector_width_float

Calls C<clGetDeviceInfo> with C<CL_DEVICE_NATIVE_VECTOR_WIDTH_FLOAT> and returns the result.

=item $uint = $device->native_vector_width_double

Calls C<clGetDeviceInfo> with C<CL_DEVICE_NATIVE_VECTOR_WIDTH_DOUBLE> and returns the result.

=item $uint = $device->native_vector_width_half

Calls C<clGetDeviceInfo> with C<CL_DEVICE_NATIVE_VECTOR_WIDTH_HALF> and returns the result.

=item $device_fp_config = $device->double_fp_config

Calls C<clGetDeviceInfo> with C<CL_DEVICE_DOUBLE_FP_CONFIG> and returns the result.

=item $device_fp_config = $device->half_fp_config

Calls C<clGetDeviceInfo> with C<CL_DEVICE_HALF_FP_CONFIG> and returns the result.

=item $boolean = $device->host_unified_memory

Calls C<clGetDeviceInfo> with C<CL_DEVICE_HOST_UNIFIED_MEMORY> and returns the result.

=item $device = $device->parent_device_ext

Calls C<clGetDeviceInfo> with C<CL_DEVICE_PARENT_DEVICE_EXT> and returns the result.

=item @device_partition_property_exts = $device->partition_types_ext

Calls C<clGetDeviceInfo> with C<CL_DEVICE_PARTITION_TYPES_EXT> and returns the result.

=item @device_partition_property_exts = $device->affinity_domains_ext

Calls C<clGetDeviceInfo> with C<CL_DEVICE_AFFINITY_DOMAINS_EXT> and returns the result.

=item $uint = $device->reference_count_ext 

Calls C<clGetDeviceInfo> with C<CL_DEVICE_REFERENCE_COUNT_EXT > and returns the result.

=item @device_partition_property_exts = $device->partition_style_ext

Calls C<clGetDeviceInfo> with C<CL_DEVICE_PARTITION_STYLE_EXT> and returns the result.

=for gengetinfo end device

=back

=head2 THE OpenCL::Context CLASS

=over 4

=item $queue = $ctx->queue ($device, $properties)

Create a new OpenCL::Queue object from the context and the given device.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateCommandQueue.html>

=item $ev = $ctx->user_event

Creates a new OpenCL::UserEvent object.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateUserEvent.html>

=item $buf = $ctx->buffer ($flags, $len)

Creates a new OpenCL::Buffer (actually OpenCL::BufferObj) object with the
given flags and octet-size.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateBuffer.html>

=item $buf = $ctx->buffer_sv ($flags, $data)

Creates a new OpenCL::Buffer (actually OpenCL::BufferObj) object and
initialise it with the given data values.

=item $img = $ctx->image2d ($flags, $channel_order, $channel_type, $width, $height, $row_pitch = 0, $data = undef)

Creates a new OpenCL::Image2D object and optionally initialises it with
the given data values.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateImage2D.html>

=item $img = $ctx->image3d ($flags, $channel_order, $channel_type, $width, $height, $depth, $row_pitch = 0, $slice_pitch = 0, $data = undef)

Creates a new OpenCL::Image3D object and optionally initialises it with
the given data values.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateImage3D.html>

=item $buffer = $ctx->gl_buffer ($flags, $bufobj)

Creates a new OpenCL::Buffer (actually OpenCL::BufferObj) object that refers to the given
OpenGL buffer object.

http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateFromGLBuffer.html

=item $ctx->gl_texture2d ($flags, $target, $miplevel, $texture)

Creates a new OpenCL::Image2D object that refers to the given OpenGL
2D texture object.

http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateFromGLTexture2D.html

=item $ctx->gl_texture3d ($flags, $target, $miplevel, $texture)

Creates a new OpenCL::Image3D object that refers to the given OpenGL
3D texture object.

http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateFromGLTexture3D.html

=item $ctx->gl_renderbuffer ($flags, $renderbuffer)

Creates a new OpenCL::Image2D object that refers to the given OpenGL
render buffer.

http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateFromGLRenderbuffer.html

=item @formats = $ctx->supported_image_formats ($flags, $image_type)

Returns a list of matching image formats - each format is an arrayref with
two values, $channel_order and $channel_type, in it.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetSupportedImageFormats.html>

=item $sampler = $ctx->sampler ($normalized_coords, $addressing_mode, $filter_mode)

Creates a new OpenCL::Sampler object.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateSampler.html>

=item $program = $ctx->program_with_source ($string)

Creates a new OpenCL::Program object from the given source code.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateProgramWithSource.html>

=item $packed_value = $ctx->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetContextInfo.html>

=for gengetinfo begin context

=item $uint = $context->reference_count

Calls C<clGetContextInfo> with C<CL_CONTEXT_REFERENCE_COUNT> and returns the result.

=item @devices = $context->devices

Calls C<clGetContextInfo> with C<CL_CONTEXT_DEVICES> and returns the result.

=item @property_ints = $context->properties

Calls C<clGetContextInfo> with C<CL_CONTEXT_PROPERTIES> and returns the result.

=item $uint = $context->num_devices

Calls C<clGetContextInfo> with C<CL_CONTEXT_NUM_DEVICES> and returns the result.

=for gengetinfo end context

=back

=head2 THE OpenCL::Queue CLASS

An OpenCL::Queue represents an execution queue for OpenCL. You execute
requests by calling their respective C<enqueue_xxx> method and waitinf for
it to complete in some way.

All the enqueue methods return an event object that can be used to wait
for completion, unless the method is called in void context, in which case
no event object is created.

They also allow you to specify any number of other event objects that this
request has to wait for before it starts executing, by simply passing the
event objects as extra parameters to the enqueue methods.

Queues execute in-order by default, without any parallelism, so in most
cases (i.e. you use only one queue) it's not necessary to wait for or
create event objects.

=over 4

=item $ev = $queue->enqueue_read_buffer ($buffer, $blocking, $offset, $len, $data, $wait_events...)

Reads data from buffer into the given string.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueReadBuffer.html>

=item $ev = $queue->enqueue_write_buffer ($buffer, $blocking, $offset, $data, $wait_events...)

Writes data to buffer from the given string.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueWriteBuffer.html>

=item $ev = $queue->enqueue_copy_buffer ($src, $dst, $src_offset, $dst_offset, $len, $wait_events...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueCopyBuffer.html>

=item $ev = $queue->enqueue_read_buffer_rect (OpenCL::Memory buf, cl_bool blocking, $buf_x, $buf_y, $buf_z, $host_x, $host_y, $host_z, $width, $height, $depth, $buf_row_pitch, $buf_slice_pitch, $host_row_pitch, $host_slice_pitch, $data, $wait_events...)

http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueReadBufferRect.html

=item $ev = $queue->enqueue_write_buffer_rect (OpenCL::Memory buf, cl_bool blocking, $buf_x, $buf_y, $buf_z, $host_x, $host_y, $host_z, $width, $height, $depth, $buf_row_pitch, $buf_slice_pitch, $host_row_pitch, $host_slice_pitch, $data, $wait_events...)

http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueWriteBufferRect.html

=item $ev = $queue->enqueue_read_image ($src, $blocking, $x, $y, $z, $width, $height, $depth, $row_pitch, $slice_pitch, $data, $wait_events...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueCopyBufferRect.html>

=item $ev = $queue->enqueue_copy_buffer_to_image ($src_buffer, $dst_image, $src_offset, $dst_x, $dst_y, $dst_z, $width, $height, $depth, $wait_events...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueReadImage.html>

=item $ev = $queue->enqueue_write_image ($src, $blocking, $x, $y, $z, $width, $height, $depth, $row_pitch, $slice_pitch, $data, $wait_events...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueWriteImage.html>

=item $ev = $queue->enqueue_copy_image ($src_image, $dst_image, $src_x, $src_y, $src_z, $dst_x, $dst_y, $dst_z, $width, $height, $depth, $wait_events...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueCopyImage.html>

=item $ev = $queue->enqueue_copy_image_to_buffer ($src_image, $dst_image, $src_x, $src_y, $src_z, $width, $height, $depth, $dst_offset, $wait_events...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueCopyImageToBuffer.html>

=item $ev = $queue->enqueue_copy_buffer_rect ($src, $dst, $src_x, $src_y, $src_z, $dst_x, $dst_y, $dst_z, $width, $height, $depth, $src_row_pitch, $src_slice_pitch, $dst_row_pitch, $dst_slice_pitch, $wait_event...)

Yeah.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueCopyBufferToImage.html>.

=item $ev = $queue->enqueue_task ($kernel, $wait_events...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueTask.html>

=item $ev = $queue->enqueue_nd_range_kernel ($kernel, @$global_work_offset, @$global_work_size, @$local_work_size, $wait_events...)

Enqueues a kernel execution.

@$global_work_size must be specified as a reference to an array of
integers specifying the work sizes (element counts).

@$global_work_offset must be either C<undef> (in which case all offsets
are C<0>), or a reference to an array of work offsets, with the same number
of elements as @$global_work_size.

@$local_work_size must be either C<undef> (in which case the
implementation is supposed to choose good local work sizes), or a
reference to an array of local work sizes, with the same number of
elements as @$global_work_size.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueNDRangeKernel.html>

=item $ev = $queue->enqueue_marker ($wait_events...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueMarker.html>

=item $ev = $queue->enqueue_acquire_gl_objects ([object, ...], $wait_events...)

Enqueues a list (an array-ref of OpenCL::Memory objects) to be acquired
for subsequent OpenCL usage.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueAcquireGLObjects.html>

=item $ev = $queue->enqueue_release_gl_objects ([object, ...], $wait_events...)

Enqueues a list (an array-ref of OpenCL::Memory objects) to be released
for subsequent OpenGL usage.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueReleaseGLObjects.html>

=item $ev = $queue->enqueue_wait_for_events ($wait_events...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueWaitForEvents.html>

=item $queue->enqueue_barrier

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueBarrier.html>

=item $queue->flush

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clFlush.html>

=item $queue->finish

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clFinish.html>

=item $packed_value = $queue->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetCommandQueueInfo.html>

=for gengetinfo begin command_queue

=item $ctx = $command_queue->context

Calls C<clGetCommandQueueInfo> with C<CL_QUEUE_CONTEXT> and returns the result.

=item $device = $command_queue->device

Calls C<clGetCommandQueueInfo> with C<CL_QUEUE_DEVICE> and returns the result.

=item $uint = $command_queue->reference_count

Calls C<clGetCommandQueueInfo> with C<CL_QUEUE_REFERENCE_COUNT> and returns the result.

=item $command_queue_properties = $command_queue->properties

Calls C<clGetCommandQueueInfo> with C<CL_QUEUE_PROPERTIES> and returns the result.

=for gengetinfo end command_queue

=back

=head2 THE OpenCL::Memory CLASS

This the superclass of all memory objects - OpenCL::Buffer, OpenCL::Image,
OpenCL::Image2D and OpenCL::Image3D.

=over 4

=item $packed_value = $memory->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetMemObjectInfo.html>

=for gengetinfo begin mem

=item $mem_object_type = $mem->type

Calls C<clGetMemObjectInfo> with C<CL_MEM_TYPE> and returns the result.

=item $mem_flags = $mem->flags

Calls C<clGetMemObjectInfo> with C<CL_MEM_FLAGS> and returns the result.

=item $int = $mem->size

Calls C<clGetMemObjectInfo> with C<CL_MEM_SIZE> and returns the result.

=item $ptr_value = $mem->host_ptr

Calls C<clGetMemObjectInfo> with C<CL_MEM_HOST_PTR> and returns the result.

=item $uint = $mem->map_count

Calls C<clGetMemObjectInfo> with C<CL_MEM_MAP_COUNT> and returns the result.

=item $uint = $mem->reference_count

Calls C<clGetMemObjectInfo> with C<CL_MEM_REFERENCE_COUNT> and returns the result.

=item $ctx = $mem->context

Calls C<clGetMemObjectInfo> with C<CL_MEM_CONTEXT> and returns the result.

=item $mem = $mem->associated_memobject

Calls C<clGetMemObjectInfo> with C<CL_MEM_ASSOCIATED_MEMOBJECT> and returns the result.

=item $int = $mem->offset

Calls C<clGetMemObjectInfo> with C<CL_MEM_OFFSET> and returns the result.

=for gengetinfo end mem

=item ($type, $name) = $mem->gl_object_info

Returns the OpenGL object type (e.g. OpenCL::GL_OBJECT_TEXTURE2D) and the
object "name" (e.g. the texture name) used to create this memory object.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetGLObjectInfo.html>

=back

=head2 THE OpenCL::Buffer CLASS

This is a subclass of OpenCL::Memory, and the superclass of
OpenCL::BufferObj. Its purpose is simply to distinguish between buffers
and sub-buffers.

=head2 THE OpenCL::BufferObj CLASS

This is a subclass of OpenCL::Buffer and thus OpenCL::Memory. It exists
because one cna create sub buffers of OpenLC::BufferObj objects, but not
sub buffers from these sub buffers.

=over 4

=item $subbuf = $buf_obj->sub_buffer_region ($flags, $origin, $size)

Creates an OpenCL::Buffer objects from this buffer and returns it. The
C<buffer_create_type> is assumed to be C<CL_BUFFER_CREATE_TYPE_REGION>.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateSubBuffer.html>

=back

=head2 THE OpenCL::Image CLASS

This is the superclass of all image objects - OpenCL::Image2D and OpenCL::Image3D.

=over 4

=item $packed_value = $ev->image_info ($name)

See C<< $platform->info >> for details.

The reason this method is not called C<info> is that there already is an
C<< ->info >> method inherited from C<OpenCL::Memory>.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetImageInfo.html>

=for gengetinfo begin image

=item $int = $image->element_size

Calls C<clGetImageInfo> with C<CL_IMAGE_ELEMENT_SIZE> and returns the result.

=item $int = $image->row_pitch

Calls C<clGetImageInfo> with C<CL_IMAGE_ROW_PITCH> and returns the result.

=item $int = $image->slice_pitch

Calls C<clGetImageInfo> with C<CL_IMAGE_SLICE_PITCH> and returns the result.

=item $int = $image->width

Calls C<clGetImageInfo> with C<CL_IMAGE_WIDTH> and returns the result.

=item $int = $image->height

Calls C<clGetImageInfo> with C<CL_IMAGE_HEIGHT> and returns the result.

=item $int = $image->depth

Calls C<clGetImageInfo> with C<CL_IMAGE_DEPTH> and returns the result.

=for gengetinfo end image

=for gengetinfo begin gl_texture

=item $GLenum = $gl_texture->target

Calls C<clGetGLTextureInfo> with C<CL_GL_TEXTURE_TARGET> and returns the result.

=item $GLint = $gl_texture->gl_mipmap_level

Calls C<clGetGLTextureInfo> with C<CL_GL_MIPMAP_LEVEL> and returns the result.

=for gengetinfo end gl_texture

=back

=head2 THE OpenCL::Sampler CLASS

=over 4

=item $packed_value = $sampler->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetSamplerInfo.html>

=for gengetinfo begin sampler

=item $uint = $sampler->reference_count

Calls C<clGetSamplerInfo> with C<CL_SAMPLER_REFERENCE_COUNT> and returns the result.

=item $ctx = $sampler->context

Calls C<clGetSamplerInfo> with C<CL_SAMPLER_CONTEXT> and returns the result.

=item $addressing_mode = $sampler->normalized_coords

Calls C<clGetSamplerInfo> with C<CL_SAMPLER_NORMALIZED_COORDS> and returns the result.

=item $filter_mode = $sampler->addressing_mode

Calls C<clGetSamplerInfo> with C<CL_SAMPLER_ADDRESSING_MODE> and returns the result.

=item $boolean = $sampler->filter_mode

Calls C<clGetSamplerInfo> with C<CL_SAMPLER_FILTER_MODE> and returns the result.

=for gengetinfo end sampler

=back

=head2 THE OpenCL::Program CLASS

=over 4

=item $program->build ($device, $options = "")

Tries to build the program with the givne options.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clBuildProgram.html>

=item $packed_value = $program->build_info ($device, $name)

Similar to C<< $platform->info >>, but returns build info for a previous
build attempt for the given device.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetBuildInfo.html>

=item $kernel = $program->kernel ($function_name)

Creates an OpenCL::Kernel object out of the named C<__kernel> function in
the program.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateKernel.html>

=for gengetinfo begin program_build

=item $build_status = $program->build_status ($device)

Calls C<clGetProgramBuildInfo> with C<CL_PROGRAM_BUILD_STATUS> and returns the result.

=item $string = $program->build_options ($device)

Calls C<clGetProgramBuildInfo> with C<CL_PROGRAM_BUILD_OPTIONS> and returns the result.

=item $string = $program->build_log ($device)

Calls C<clGetProgramBuildInfo> with C<CL_PROGRAM_BUILD_LOG> and returns the result.

=for gengetinfo end program_build

=item $packed_value = $program->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetProgramInfo.html>

=for gengetinfo begin program

=item $uint = $program->reference_count

Calls C<clGetProgramInfo> with C<CL_PROGRAM_REFERENCE_COUNT> and returns the result.

=item $ctx = $program->context

Calls C<clGetProgramInfo> with C<CL_PROGRAM_CONTEXT> and returns the result.

=item $uint = $program->num_devices

Calls C<clGetProgramInfo> with C<CL_PROGRAM_NUM_DEVICES> and returns the result.

=item @devices = $program->devices

Calls C<clGetProgramInfo> with C<CL_PROGRAM_DEVICES> and returns the result.

=item $string = $program->source

Calls C<clGetProgramInfo> with C<CL_PROGRAM_SOURCE> and returns the result.

=item @ints = $program->binary_sizes

Calls C<clGetProgramInfo> with C<CL_PROGRAM_BINARY_SIZES> and returns the result.

=for gengetinfo end program

=item @blobs = $program->binaries

Returns a string for the compiled binary for every device associated with
the program, empty strings indicate missing programs, and an empty result
means no program binaries are available.

These "binaries" are often, in fact, informative low-level assembly
sources.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetProgramInfo.html>

=back

=head2 THE OpenCL::Kernel CLASS

=over 4

=item $packed_value = $kernel->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetKernelInfo.html>

=for gengetinfo begin kernel

=item $string = $kernel->function_name

Calls C<clGetKernelInfo> with C<CL_KERNEL_FUNCTION_NAME> and returns the result.

=item $uint = $kernel->num_args

Calls C<clGetKernelInfo> with C<CL_KERNEL_NUM_ARGS> and returns the result.

=item $uint = $kernel->reference_count

Calls C<clGetKernelInfo> with C<CL_KERNEL_REFERENCE_COUNT> and returns the result.

=item $ctx = $kernel->context

Calls C<clGetKernelInfo> with C<CL_KERNEL_CONTEXT> and returns the result.

=item $program = $kernel->program

Calls C<clGetKernelInfo> with C<CL_KERNEL_PROGRAM> and returns the result.

=for gengetinfo end kernel

=item $packed_value = $kernel->work_group_info ($device, $name)

See C<< $platform->info >> for details.

The reason this method is not called C<info> is that there already is an
C<< ->info >> method.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetKernelWorkGroupInfo.html>

=for gengetinfo begin kernel_work_group

=item $int = $kernel->work_group_size ($device)

Calls C<clGetKernelWorkGroupInfo> with C<CL_KERNEL_WORK_GROUP_SIZE> and returns the result.

=item @ints = $kernel->compile_work_group_size ($device)

Calls C<clGetKernelWorkGroupInfo> with C<CL_KERNEL_COMPILE_WORK_GROUP_SIZE> and returns the result.

=item $ulong = $kernel->local_mem_size ($device)

Calls C<clGetKernelWorkGroupInfo> with C<CL_KERNEL_LOCAL_MEM_SIZE> and returns the result.

=item $int = $kernel->preferred_work_group_size_multiple ($device)

Calls C<clGetKernelWorkGroupInfo> with C<CL_KERNEL_PREFERRED_WORK_GROUP_SIZE_MULTIPLE> and returns the result.

=item $ulong = $kernel->private_mem_size ($device)

Calls C<clGetKernelWorkGroupInfo> with C<CL_KERNEL_PRIVATE_MEM_SIZE> and returns the result.

=for gengetinfo end kernel_work_group

=item $kernel->set_TYPE ($index, $value)

This is a family of methods to set the kernel argument with the number C<$index> to the give C<$value>.

TYPE is one of C<char>, C<uchar>, C<short>, C<ushort>, C<int>, C<uint>,
C<long>, C<ulong>, C<half>, C<float>, C<double>, C<memory>, C<buffer>,
C<image2d>, C<image3d>, C<sampler> or C<event>.

Chars and integers (including the half type) are specified as integers,
float and double as floating point values, memory/buffer/image2d/image3d
must be an object of that type or C<undef>, and sampler and event must be
objects of that type.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clSetKernelArg.html>

=back

=head2 THE OpenCL::Event CLASS

This is the superclass for all event objects (including OpenCL::UserEvent
objects).

=over 4

=item $ev->wait

Waits for the event to complete.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clWaitForEvents.html>

=item $packed_value = $ev->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetEventInfo.html>

=for gengetinfo begin event

=item $queue = $event->command_queue

Calls C<clGetEventInfo> with C<CL_EVENT_COMMAND_QUEUE> and returns the result.

=item $command_type = $event->command_type

Calls C<clGetEventInfo> with C<CL_EVENT_COMMAND_TYPE> and returns the result.

=item $uint = $event->reference_count

Calls C<clGetEventInfo> with C<CL_EVENT_REFERENCE_COUNT> and returns the result.

=item $uint = $event->command_execution_status

Calls C<clGetEventInfo> with C<CL_EVENT_COMMAND_EXECUTION_STATUS> and returns the result.

=item $ctx = $event->context

Calls C<clGetEventInfo> with C<CL_EVENT_CONTEXT> and returns the result.

=for gengetinfo end event

=item $packed_value = $ev->profiling_info ($name)

See C<< $platform->info >> for details.

The reason this method is not called C<info> is that there already is an
C<< ->info >> method.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetProfilingInfo.html>

=for gengetinfo begin profiling

=item $ulong = $event->profiling_command_queued

Calls C<clGetEventProfilingInfo> with C<CL_PROFILING_COMMAND_QUEUED> and returns the result.

=item $ulong = $event->profiling_command_submit

Calls C<clGetEventProfilingInfo> with C<CL_PROFILING_COMMAND_SUBMIT> and returns the result.

=item $ulong = $event->profiling_command_start

Calls C<clGetEventProfilingInfo> with C<CL_PROFILING_COMMAND_START> and returns the result.

=item $ulong = $event->profiling_command_end

Calls C<clGetEventProfilingInfo> with C<CL_PROFILING_COMMAND_END> and returns the result.

=for gengetinfo end profiling

=back

=head2 THE OpenCL::UserEvent CLASS

This is a subclass of OpenCL::Event.

=over 4

=item $ev->set_status ($execution_status)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clSetUserEventStatus.html>

=back

=cut

package OpenCL;

use common::sense;

BEGIN {
   our $VERSION = '0.95';

   require XSLoader;
   XSLoader::load (__PACKAGE__, $VERSION);

   @OpenCL::Buffer::ISA =
   @OpenCL::Image::ISA      = OpenCL::Memory::;

   @OpenCL::BufferObj::ISA  = OpenCL::Buffer::;

   @OpenCL::Image2D::ISA    =
   @OpenCL::Image3D::ISA    = OpenCL::Image::;

   @OpenCL::UserEvent::ISA  = OpenCL::Event::;
}

1;

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

