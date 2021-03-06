package Moose::Meta::Role::Application::ToClass;

use strict;
use warnings;
use metaclass;

use Moose::Util  'english_list';
use Scalar::Util 'weaken', 'blessed';

our $VERSION   = '0.85';
$VERSION = eval $VERSION;
our $AUTHORITY = 'cpan:STEVAN';

use base 'Moose::Meta::Role::Application';

__PACKAGE__->meta->add_attribute('role' => (
    reader => 'role',
));

__PACKAGE__->meta->add_attribute('class' => (
    reader => 'class',
));

sub apply {
    my ($self, $role, $class) = @_;

    # We need weak_ref in CMOP :(
    weaken($self->{role}  = $role);
    weaken($self->{class} = $class);

    $self->SUPER::apply($role, $class);

    $class->add_role($role);
    $class->add_role_application($self);
}

sub check_role_exclusions {
    my ($self, $role, $class) = @_;
    if ($class->excludes_role($role->name)) {
        $class->throw_error("Conflict detected: " . $class->name . " excludes role '" . $role->name . "'");
    }
    foreach my $excluded_role_name ($role->get_excluded_roles_list) {
        if ($class->does_role($excluded_role_name)) {
            $class->throw_error("The class " . $class->name . " does the excluded role '$excluded_role_name'");
        }
    }
}

sub check_required_methods {
    my ($self, $role, $class) = @_;

    my @missing;
    my @is_attr;

    # NOTE:
    # we might need to move this down below the
    # the attributes so that we can require any
    # attribute accessors. However I am thinking
    # that maybe those are somehow exempt from
    # the require methods stuff.
    foreach my $required_method ($role->get_required_method_list) {
        my $required_method_name = $required_method->name;

        if (!$class->find_method_by_name($required_method_name)) {

            next if $self->is_aliased_method($required_method_name);

            push @missing, $required_method;
        }
    }

    return unless @missing;

    my $error = '';

    my @conflicts = grep { $_->isa('Moose::Meta::Role::Method::Conflicting') } @missing;

    if (@conflicts) {
        my $conflict = $conflicts[0];
        my $roles = Moose::Util::english_list( map { q{'} . $_ . q{'} } @{ $conflict->roles } );

        $error
            .= "Due to a method name conflict in roles "
            .  $roles
            . ", the method '"
            . $conflict->name
            . "' must be implemented or excluded by '"
            . $class->name
            . q{'};
    }
    elsif (@missing) {
        my $noun = @missing == 1 ? 'method' : 'methods';

        my $list
            = Moose::Util::english_list( map { q{'} . $_ . q{'} } @missing );

        $error
            .= q{'}
            . $role->name
            . "' requires the $noun $list "
            . "to be implemented by '"
            . $class->name . q{'};
    }

    $class->throw_error($error);
}

sub check_required_attributes {

}

sub apply_attributes {
    my ($self, $role, $class) = @_;
    foreach my $attribute_name ($role->get_attribute_list) {
        # it if it has one already
        if ($class->has_attribute($attribute_name) &&
            # make sure we haven't seen this one already too
            $class->get_attribute($attribute_name) != $role->get_attribute($attribute_name)) {
            next;
        }
        else {
            $class->add_attribute(
                $attribute_name,
                $role->get_attribute($attribute_name)
            );
        }
    }
}

sub apply_methods {
    my ($self, $role, $class) = @_;
    foreach my $method_name ($role->get_method_list) {

        unless ($self->is_method_excluded($method_name)) {
            # it if it has one already
            if ($class->has_method($method_name) &&
                # and if they are not the same thing ...
                $class->get_method($method_name)->body != $role->get_method($method_name)->body) {
                next;
            }
            else {
                # add it, although it could be overridden
                $class->add_method(
                    $method_name,
                    $role->get_method($method_name)
                );
            }
        }

        if ($self->is_method_aliased($method_name)) {
            my $aliased_method_name = $self->get_method_aliases->{$method_name};
            # it if it has one already
            if ($class->has_method($aliased_method_name) &&
                # and if they are not the same thing ...
                $class->get_method($aliased_method_name)->body != $role->get_method($method_name)->body) {
                $class->throw_error("Cannot create a method alias if a local method of the same name exists");
            }
            $class->add_method(
                $aliased_method_name,
                $role->get_method($method_name)
            );
        }
    }
    # we must reset the cache here since
    # we are just aliasing methods, otherwise
    # the modifiers go wonky.
    $class->reset_package_cache_flag;
}

sub apply_override_method_modifiers {
    my ($self, $role, $class) = @_;
    foreach my $method_name ($role->get_method_modifier_list('override')) {
        # it if it has one already then ...
        if ($class->has_method($method_name)) {
            next;
        }
        else {
            # if this is not a role, then we need to
            # find the original package of the method
            # so that we can tell the class were to
            # find the right super() method
            my $method = $role->get_override_method_modifier($method_name);
            my ($package) = Class::MOP::get_code_info($method);
            # if it is a class, we just add it
            $class->add_override_method_modifier($method_name, $method, $package);
        }
    }
}

sub apply_method_modifiers {
    my ($self, $modifier_type, $role, $class) = @_;
    my $add = "add_${modifier_type}_method_modifier";
    my $get = "get_${modifier_type}_method_modifiers";
    foreach my $method_name ($role->get_method_modifier_list($modifier_type)) {
        $class->$add(
            $method_name,
            $_
        ) foreach $role->$get($method_name);
    }
}

1;

__END__

=pod

=head1 NAME

Moose::Meta::Role::Application::ToClass - Compose a role into a class

=head1 DESCRIPTION

=head2 METHODS

=over 4

=item B<new>

=item B<meta>

=item B<apply>

=item B<check_role_exclusions>

=item B<check_required_methods>

=item B<check_required_attributes>

=item B<apply_attributes>

=item B<apply_methods>

=item B<apply_method_modifiers>

=item B<apply_override_method_modifiers>

=back

=head1 BUGS

All complex software has bugs lurking in it, and this module is no
exception. If you find a bug please either email me, or add the bug
to cpan-RT.

=head1 AUTHOR

Stevan Little E<lt>stevan@iinteractive.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006-2009 by Infinity Interactive, Inc.

L<http://www.iinteractive.com>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

