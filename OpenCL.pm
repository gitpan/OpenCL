=head1 NAME

OpenCL - bindings to, well, OpenCL

=head1 SYNOPSIS

 use OpenCL;

=head1 DESCRIPTION

This is an early release which is not useful yet.

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

=over 4

=cut

package OpenCL;

BEGIN {
   $VERSION = '0.01';

   require XSLoader;
   XSLoader::load (__PACKAGE__, $VERSION);
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

