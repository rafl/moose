package Moose::Meta::TypeConstraint::Role;

use strict;
use warnings;
use metaclass;

use Scalar::Util 'blessed';
use Moose::Util::TypeConstraints ();

our $VERSION   = '0.64';
$VERSION = eval $VERSION;
our $AUTHORITY = 'cpan:STEVAN';

use base 'Moose::Meta::TypeConstraint';

__PACKAGE__->meta->add_attribute('role' => (
    reader => 'role',
));

sub new {
    my ( $class, %args ) = @_;

    $args{parent} = Moose::Util::TypeConstraints::find_type_constraint('Role');
    my $self      = $class->_new(\%args);

    $self->_create_hand_optimized_type_constraint;
    $self->compile_type_constraint();

    return $self;
}

sub _create_hand_optimized_type_constraint {
    my $self = shift;
    my $role = $self->role;
    $self->hand_optimized_type_constraint(
        sub { Moose::Util::does_role($_[0], $role) }
    );
}

sub parents {
    my $self = shift;
    return (
        $self->parent,
        map {
            # FIXME find_type_constraint might find a TC named after the role but that isn't really it
            # I did this anyway since it's a convention that preceded TypeConstraint::Role, and it should DWIM
            # if anybody thinks this problematic please discuss on IRC.
            # a possible fix is to add by attr indexing to the type registry to find types of a certain property
            # regardless of their name
            Moose::Util::TypeConstraints::find_type_constraint($_) 
                || 
            __PACKAGE__->new( role => $_, name => "__ANON__" )
        } @{ $self->role->meta->get_roles },
    );
}

sub equals {
    my ( $self, $type_or_name ) = @_;

    my $other = Moose::Util::TypeConstraints::find_type_constraint($type_or_name);

    return unless defined $other;
    return unless $other->isa(__PACKAGE__);

    return $self->role eq $other->role;
}

sub is_a_type_of {
    my ($self, $type_or_name) = @_;

    my $type = Moose::Util::TypeConstraints::find_type_constraint($type_or_name);

    ($self->equals($type) || $self->is_subtype_of($type_or_name));
}

sub is_subtype_of {
    my ($self, $type_or_name_or_role ) = @_;

    if ( not ref $type_or_name_or_role ) {
        # it might be a role
        return 1 if $self->role->meta->does_role( $type_or_name_or_role );
    }

    my $type = Moose::Util::TypeConstraints::find_type_constraint($type_or_name_or_role);

    return unless defined $type;
    
    if ( $type->isa(__PACKAGE__) ) {
        # if $type_or_name_or_role isn't a role, it might be the TC name of another ::Role type
        # or it could also just be a type object in this branch
        return $self->role->meta->does_role( $type->role );
    } else {
        # the only other thing we are a subtype of is Object
        $self->SUPER::is_subtype_of($type);
    }
}

sub create_child_type {
    my ($self, @args) = @_;
    return Moose::Meta::TypeConstraint->new(@args, parent => $self);
}

1;

__END__

=pod

=head1 NAME

Moose::Meta::TypeConstraint::Role - Role/TypeConstraint parallel hierarchy

=head1 METHODS

=over 4

=item B<new>

=item B<role>

=item B<hand_optimized_type_constraint>

=item B<has_hand_optimized_type_constraint>

=item B<equals>

=item B<is_a_type_of>

=item B<is_subtype_of>

=item B<create_child_type>

=item B<parents>

Return all the parent types, corresponding to the parent classes.

=item B<meta>

=back

=head1 BUGS

All complex software has bugs lurking in it, and this module is no 
exception. If you find a bug please either email me, or add the bug
to cpan-RT.

=head1 AUTHOR

Yuval Kogman E<lt>nothingmuch@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006-2008 by Infinity Interactive, Inc.

L<http://www.iinteractive.com>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
