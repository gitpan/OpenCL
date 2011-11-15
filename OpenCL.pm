=head1 NAME

OpenCL - bindings to, well, OpenCL

=head1 SYNOPSIS

 use OpenCL;

=head1 DESCRIPTION

This is an early release which is not useful yet.

=head1 HELPFUL RESOURCES

The OpenCL spec used to dveelop this module (1.2 spec was available, but
no implementation was available to me :).

   http://www.khronos.org/registry/cl/specs/opencl-1.1.pdf

OpenCL manpages:

   http://www.khronos.org/registry/cl/sdk/1.1/docs/man/xhtml/

=head1 EXAMPLES

Enumerate all devices and get contexts for them;

   for my $platform (OpenCL::platforms) {
      warn $platform->info (OpenCL::PLATFORM_NAME);
      warn $platform->info (OpenCL::PLATFORM_EXTENSIONS);
      for my $device ($platform->devices) {
         warn $device->info (OpenCL::DEVICE_NAME);
         my $ctx = $device->context_simple;
         # do stuff
      }
   }

Get a useful context and a command queue:

   my $dev = ((OpenCL::platforms)[0]->devices)[0];
   my $ctx = $dev->context_simple;
   my $queue = $ctx->command_queue_simple ($dev);

Create a buffer with some predefined data, read it back synchronously,
then asynchronously:

   my $buf = $ctx->buffer_sv (OpenCL::MEM_COPY_HOST_PTR, "helmut");

   $queue->enqueue_read_buffer ($buf, 1, 1, 3, my $data);
   warn $data;

   my $ev = $queue->enqueue_read_buffer ($buf, 0, 1, 3, my $data);
   $ev->wait;
   warn $data;

Print all supported image formats:

   for my $type (OpenCL::MEM_OBJECT_IMAGE2D, OpenCL::MEM_OBJECT_IMAGE3D) {
      say "supported image formats for ", OpenCL::enum2str $type;
      
      for my $f ($ctx->supported_image_formats (0, $type)) {
         printf "  %-10s %-20s\n", OpenCL::enum2str $f->[0], OpenCL::enum2str $f->[1];
      }
   }

Create and build a program, then create a kernel out of one of its
functions:

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

Create some input and output float buffers, then call squareit on them:

   my $input  = $ctx->buffer_sv (OpenCL::MEM_COPY_HOST_PTR, pack "f*", 1, 2, 3, 4.5);
   my $output = $ctx->buffer (0, OpenCL::SIZEOF_FLOAT * 5);

   # set buffer
   $kernel->set_buffer (0, $input);
   $kernel->set_buffer (1, $output);

   # execute it for all 4 numbers
   $queue->enqueue_nd_range_kernel ($kernel, undef, [4], undef);

   # enqueue a barrier ot ensure in-order execution (not really needed in this case)
   $queue->enqueue_barrier;

   # enqueue an async read (could easily be blocking here though), then wait for it:
   my $ev = $queue->enqueue_read_buffer ($output, 0, 0, OpenCL::SIZEOF_FLOAT * 4, my $data);
   $ev->wait;

   # print the results:
   say join ", ", unpack "f*", $data;

=over 4

=cut

package OpenCL;

use common::sense;

BEGIN {
   our $VERSION = '0.02';

   require XSLoader;
   XSLoader::load (__PACKAGE__, $VERSION);

   @OpenCL::Buffer::ISA =
   @OpenCL::Image::ISA = OpenCL::Memory::;

   @OpenCL::Image2D::ISA =
   @OpenCL::Image3D::ISA = OpenCL::Image::;
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

