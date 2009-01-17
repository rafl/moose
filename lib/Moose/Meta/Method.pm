package Moose::Meta::Method;

use strict;
use warnings;

our $VERSION   = '0.64';
$VERSION = eval $VERSION;
our $AUTHORITY = 'cpan:STEVAN';

use base 'Class::MOP::Method';

sub _error_thrower {
    my $self = shift;
    ( ref $self && $self->associated_metaclass ) || "Moose::Meta::Class";
}

sub throw_error {
    my $self = shift;
    my $inv = $self->_error_thrower;
    unshift @_, "message" if @_ % 2 == 1;
    unshift @_, method => $self if ref $self;
    unshift @_, $inv;
    my $handler = $inv->can("throw_error");
    goto $handler; # to avoid incrementing depth by 1
}

sub _inline_throw_error {
    my ( $self, $msg, $args ) = @_;
    "\$meta->throw_error($msg" . ($args ? ", $args" : "") . ")"; # FIXME makes deparsing *REALLY* hard
}

1;

__END__

=pod

=head1 NAME

Moose::Meta::Method - A Moose Method metaclass

=head1 DESCRIPTION

For now, this is nothing but a subclass of Class::MOP::Method, 
but with the expanding role of the method sub-protocol, it might 
be more useful later on. 

=head1 METHODS

=over 4

=item throw_error $msg, %args

=item _inline_throw_error $msg_expr, $args_expr

=back

=head1 BUGS

All complex software has bugs lurking in it, and this module is no 
exception. If you find a bug please either email me, or add the bug
to cpan-RT.

=head1 AUTHOR

Stevan Little E<lt>stevan@iinteractive.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006-2008 by Infinity Interactive, Inc.

L<http://www.iinteractive.com>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
