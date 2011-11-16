=head1 NAME

OpenCL - Open Computing Language Bindings

=head1 SYNOPSIS

 use OpenCL;

=head1 DESCRIPTION

This is an early release which might be useful, but hasn't seen much testing.

=head1 HELPFUL RESOURCES

The OpenCL spec used to develop this module (1.2 spec was available, but
no implementation was available to me :).

   http://www.khronos.org/registry/cl/specs/opencl-1.1.pdf

OpenCL manpages:

   http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/

=head1 EXAMPLES

=head2 Enumerate all devices and get contexts for them.

   for my $platform (OpenCL::platforms) {
      warn $platform->info (OpenCL::PLATFORM_NAME);
      warn $platform->info (OpenCL::PLATFORM_EXTENSIONS);
      for my $device ($platform->devices) {
         warn $device->info (OpenCL::DEVICE_NAME);
         my $ctx = $device->context_simple;
         # do stuff
      }
   }

=head2 Get a useful context and a command queue.

   my $dev = ((OpenCL::platforms)[0]->devices)[0];
   my $ctx = $dev->context_simple;
   my $queue = $ctx->command_queue_simple ($dev);

=head2 Print all supported image formats of a context.

   for my $type (OpenCL::MEM_OBJECT_IMAGE2D, OpenCL::MEM_OBJECT_IMAGE3D) {
      say "supported image formats for ", OpenCL::enum2str $type;
      
      for my $f ($ctx->supported_image_formats (0, $type)) {
         printf "  %-10s %-20s\n", OpenCL::enum2str $f->[0], OpenCL::enum2str $f->[1];
      }
   }

=head2 Create a buffer with some predefined data, read it back synchronously,
then asynchronously.

   my $buf = $ctx->buffer_sv (OpenCL::MEM_COPY_HOST_PTR, "helmut");

   $queue->enqueue_read_buffer ($buf, 1, 1, 3, my $data);
   warn $data;

   my $ev = $queue->enqueue_read_buffer ($buf, 0, 1, 3, my $data);
   $ev->wait;
   warn $data;

=head2 Create and build a program, then create a kernel out of one of its
functions.

   my $src = '
      __kernel void
      squareit (__global float *input, __global float *output)
      {
        size_t id = get_global_id (0);
        output [id] = input [id] * input [id];
      }
   ';

   my $prog = $ctx->program_with_source ($src);

   eval { $prog->build ($dev); 1 }
      or die $prog->build_info ($dev, OpenCL::PROGRAM_BUILD_LOG);

   my $kernel = $prog->kernel ("squareit");

=head2 Create some input and output float buffers, then call squareit on them.

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
   say join ", ", unpack "f*", $data;

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

=head1 DOCUMENTATION

=head2 BASIC CONVENTIONS

This is not a 1:1 C-style translation of OpenCL to Perl - instead I
attempted to make the interface as type-safe as possible and introducing
object syntax where it makes sense. There are a number of important
differences between the OpenCL C API and this module:

=over 4

=item * Object lifetime managament is automatic - there is no need
to free objects explicitly (C<clReleaseXXX>), the release function
is called automatically once all Perl references to it go away.

=item * OpenCL uses CamelCase for function names (C<clGetPlatformInfo>),
while this module uses underscores as word separator and often leaves out
prefixes (C<< $platform->info >>).

=item * OpenCL often specifies fixed vector function arguments as short
arrays (C<size_t origin[3]>), while this module explicitly expects the
components as separate arguments-

=item * Where possible, the row_pitch value is calculated from the perl
scalar length and need not be specified.

=item * When enqueuing commands, the wait list is specified by adding
extra arguments to the function - everywhere a C<$wait_events...> argument
is documented this can be any number of event objects.

=item * When enqueuing commands, if the enqueue method is called in void
context, no event is created. In all other contexts an event is returned
by the method.

=item * This module expects all functions to return C<CL_SUCCESS>. If any
other status is returned the function will throw an exception, so you
don't normally have to to any error checking.

=back

=head2 PERL AND OPENCL TYPES

This handy(?) table lists OpenCL types and their perl and pack/unpack
format equivalents:

   OpenCL    perl   pack/unpack
   char      IV     c
   uchar     IV     C
   short     IV     s
   ushort    IV     S
   int       IV     l
   uint      IV     L
   long      IV     q
   ulong     IV     Q
   float     NV     f
   half      IV     S
   double    NV     d

=head2 THE OpenCL PACKAGE

=over 4

=item $int = OpenCL::errno

The last error returned by a function - it's only changed on errors.

=item $str = OpenCL::err2str $errval

Comverts an error value into a human readable string.

=item $str = OpenCL::err2str $enum

Converts most enum values (inof parameter names, image format constants,
object types, addressing and filter modes, command types etc.) into a
human readbale string. When confronted with some random integer it can be
very helpful to pass it through this function to maybe get some readable
string out of it.

=item @platforms = OpenCL::platforms

Returns all available OpenCL::Platform objects.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetPlatformIDs.html>

=item $ctx = OpenCL::context_from_type_simple $type = OpenCL::DEVICE_TYPE_DEFAULT

Tries to create a context from a default device and platform - never worked for me.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateContextFromType.html>

=item OpenCL::wait_for_events $wait_events...

Waits for all events to complete.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clWaitForEvents.html>

=back

=head2 THE OpenCL::Platform CLASS

=over 4

=item $packed_value = $platform->info ($name)

Calls C<clGetPlatformInfo> and returns the packed, raw value - for
strings, this will be the string, for other values you probably need to
use the correct C<unpack>. This might get improved in the future. Hopefully.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetPlatformInfo.html>

=item @devices = $platform->devices ($type = OpenCL::DEVICE_TYPE_ALL)

Returns a list of matching OpenCL::Device objects.

=item $ctx = $platform->context_from_type_simple ($type = OpenCL::DEVICE_TYPE_DEFAULT)

Tries to create a context. Never worked for me.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateContextFromType.html>

=back

=head2 THE OpenCL::Device CLASS

=over 4

=item $packed_value = $device->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetDeviceInfo.html>

=item $ctx = $device->context_simple

Convenience function to create a new OpenCL::Context object.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateContext.html>

=back

=head2 THE OpenCL::Context CLASS

=over 4

=item $packed_value = $ctx->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetContextInfo.html>

=item $queue = $ctx->command_queue_simple ($device)

Convenience function to create a new OpenCL::Queue object from the context and the given device.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateCommandQueue.html>

=item $ev = $ctx->user_event

Creates a new OpenCL::UserEvent object.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateUserEvent.html>

=item $buf = $ctx->buffer ($flags, $len)

Creates a new OpenCL::Buffer object with the given flags and octet-size.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateBuffer.html>

=item $buf = $ctx->buffer_sv ($flags, $data)

Creates a new OpenCL::Buffer object and initialise it with the given data values.

=item $img = $ctx->image2d ($flags, $channel_order, $channel_type, $width, $height, $data)

Creates a new OpenCL::Image2D object and optionally initialises it with the given data values.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateImage2D.html>

=item $img = $ctx->image3d ($flags, $channel_order, $channel_type, $width, $height, $depth, $slice_pitch, $data)

Creates a new OpenCL::Image3D object and optionally initialises it with the given data values.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clCreateImage3D.html>

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

=item $packed_value = $ctx->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetCommandQueueInfo.html>

=item $ev = $queue->enqueue_read_buffer ($buffer, $blocking, $offset, $len, $data, $wait_events...)

Reads data from buffer into the given string.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueReadBuffer.html>

=item $ev = $queue->enqueue_write_buffer ($buffer, $blocking, $offset, $data, $wait_events...)

Writes data to buffer from the given string.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueWriteBuffer.html>

=item $ev = $queue->enqueue_copy_buffer ($src, $dst, $src_offset, $dst_offset, $len, $wait_events...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueCopyBuffer.html>

=item $ev = $queue->enqueue_read_image ($src, $blocking, $x, $y, $z, $width, $height, $depth, $row_pitch, $slice_pitch, $data, $wait_events...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueReadImage.html>

=item $ev = $queue->enqueue_write_image ($src, $blocking, $x, $y, $z, $width, $height, $depth, $row_pitch, $data, $wait_events...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueWriteImage.html>

=item $ev = $queue->enqueue_copy_buffer_rect ($src, $dst, $src_x, $src_y, $src_z, $dst_x, $dst_y, $dst_z, $width, $height, $depth, $src_row_pitch, $src_slice_pitch, 4dst_row_pitch, $dst_slice_pitch, $ait_event...)

Yeah.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueCopyBufferRect.html>

=item $ev = $queue->enqueue_copy_buffer_to_image (OpenCL::Buffer src, OpenCL::Image dst, size_t src_offset, size_t dst_x, size_t dst_y, size_t dst_z, size_t width, size_t height, size_t depth, ...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueCopyBufferToImage.html>.

=item $ev = $queue->enqueue_copy_image (OpenCL::Image src, OpenCL::Buffer dst, size_t src_x, size_t src_y, size_t src_z, size_t dst_x, size_t dst_y, size_t dst_z, size_t width, size_t height, size_t depth, ...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueCopyImage.html>

=item $ev = $queue->enqueue_copy_image_to_buffer (OpenCL::Image src, OpenCL::Buffer dst, size_t src_x, size_t src_y, size_t src_z, size_t width, size_t height, size_t depth, size_t dst_offset, ...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueCopyImageToBuffer.html>

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

=item $ev = $queue->enqueue_marker

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueMarker.html>

=item $ev = $queue->enqueue_wait_for_events ($wait_events...)

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueWaitForEvents.html>

=item $queue->enqueue_barrier

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clEnqueueBarrier.html>

=item $queue->flush

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clFlush.html>

=item $queue->finish

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clFinish.html>

=back

=head2 THE OpenCL::Memory CLASS

This the superclass of all memory objects - OpenCL::Buffer, OpenCL::Image,
OpenCL::Image2D and OpenCL::Image3D. The subclasses of this class
currently only exist to allow type-checking.

=over 4

=item $packed_value = $memory->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetMemObjectInfo.html>

=back

=head2 THE OpenCL::Sampler CLASS

=over 4

=item $packed_value = $sampler->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetSamplerInfo.html>

=back

=head2 THE OpenCL::Program CLASS

=over 4

=item $packed_value = $program->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetProgramInfo.html>

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

=back

=head2 THE OpenCL::Kernel CLASS

=over 4

=item $packed_value = $kernel->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetKernelInfo.html>

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

=item $packed_value = $ev->info ($name)

See C<< $platform->info >> for details.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clGetEventInfo.html>

=item $ev->wait

Waits for the event to complete.

L<http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/clWaitForEvents.html>

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
   our $VERSION = '0.03';

   require XSLoader;
   XSLoader::load (__PACKAGE__, $VERSION);

   @OpenCL::Buffer::ISA    =
   @OpenCL::Image::ISA     = OpenCL::Memory::;

   @OpenCL::Image2D::ISA   =
   @OpenCL::Image3D::ISA   = OpenCL::Image::;

   @OpenCL::UserEvent::ISA = OpenCL::Event::;
}

1;

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

