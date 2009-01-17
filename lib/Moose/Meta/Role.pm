
package Moose::Meta::Role;

use strict;
use warnings;
use metaclass;

use Scalar::Util 'blessed';
use Carp         'confess';

our $VERSION   = '0.64';
$VERSION = eval $VERSION;
our $AUTHORITY = 'cpan:STEVAN';

use Moose::Meta::Class;
use Moose::Meta::Role::Method;
use Moose::Meta::Role::Method::Required;

use base 'Class::MOP::Module';

## ------------------------------------------------------------------
## NOTE:
## I normally don't do this, but I am doing
## a whole bunch of meta-programmin in this
## module, so it just makes sense. For a clearer
## picture of what is going on in the next 
## several lines of code, look at the really 
## big comment at the end of this file (right
## before the POD).
## - SL
## ------------------------------------------------------------------

my $META = __PACKAGE__->meta;

## ------------------------------------------------------------------
## attributes ...

# NOTE:
# since roles are lazy, we hold all the attributes
# of the individual role in 'statis' until which
# time when it is applied to a class. This means
# keeping a lot of things in hash maps, so we are
# using a little of that meta-programmin' magic
# here an saving lots of extra typin. And since 
# many of these attributes above require similar
# functionality to support them, so we again use
# the wonders of meta-programmin' to deliver a
# very compact solution to this normally verbose
# problem.
# - SL

foreach my $action (
    {
        name        => 'excluded_roles_map',
        attr_reader => 'get_excluded_roles_map' ,
        methods     => {
            add       => 'add_excluded_roles',
            get_list  => 'get_excluded_roles_list',
            existence => 'excludes_role',
        }
    },
    {
        name        => 'required_methods',
        attr_reader => 'get_required_methods_map',
        methods     => {
            add       => 'add_required_methods',
            remove    => 'remove_required_methods',
            get_list  => 'get_required_method_list',
            existence => 'requires_method',
        }
    },  
    {
        name        => 'attribute_map',
        attr_reader => 'get_attribute_map',
        methods     => {
            get       => 'get_attribute',
            get_list  => 'get_attribute_list',
            existence => 'has_attribute',
            remove    => 'remove_attribute',
        }
    }
) {

    my $attr_reader = $action->{attr_reader};
    my $methods     = $action->{methods};

    # create the attribute
    $META->add_attribute($action->{name} => (
        reader  => $attr_reader,
        default => sub { {} }
    ));

    # create some helper methods
    $META->add_method($methods->{add} => sub {
        my ($self, @values) = @_;
        $self->$attr_reader->{$_} = undef foreach @values;
    }) if exists $methods->{add};

    $META->add_method($methods->{get_list} => sub {
        my ($self) = @_;
        keys %{$self->$attr_reader};
    }) if exists $methods->{get_list};

    $META->add_method($methods->{get} => sub {
        my ($self, $name) = @_;
        $self->$attr_reader->{$name}
    }) if exists $methods->{get};

    $META->add_method($methods->{existence} => sub {
        my ($self, $name) = @_;
        exists $self->$attr_reader->{$name} ? 1 : 0;
    }) if exists $methods->{existence};

    $META->add_method($methods->{remove} => sub {
        my ($self, @values) = @_;
        delete $self->$attr_reader->{$_} foreach @values;
    }) if exists $methods->{remove};
}

## some things don't always fit, so they go here ...

sub add_attribute {
    my $self = shift;
    my $name = shift;
    (defined $name && $name)
        || Moose->throw_error("You must provide a name for the attribute");
    my $attr_desc;
    if (scalar @_ == 1 && ref($_[0]) eq 'HASH') {
        $attr_desc = $_[0];
    }
    else {
        $attr_desc = { @_ };
    }
    $self->get_attribute_map->{$name} = $attr_desc;
}

# DEPRECATED 
# sub _clean_up_required_methods {
#     my $self = shift;
#     foreach my $method ($self->get_required_method_list) {
#         $self->remove_required_methods($method)
#             if $self->has_method($method);
#     }
# }

## ------------------------------------------------------------------
## method modifiers

# NOTE:
# the before/around/after method modifiers are
# stored by name, but there can be many methods
# then associated with that name. So again we have
# lots of similar functionality, so we can do some
# meta-programmin' and save some time.
# - SL

foreach my $modifier_type (qw[ before around after ]) {

    my $attr_reader = "get_${modifier_type}_method_modifiers_map";
    
    # create the attribute ...
    $META->add_attribute("${modifier_type}_method_modifiers" => (
        reader  => $attr_reader,
        default => sub { {} }
    ));  

    # and some helper methods ...
    $META->add_method("get_${modifier_type}_method_modifiers" => sub {
        my ($self, $method_name) = @_;
        #return () unless exists $self->$attr_reader->{$method_name};
        @{$self->$attr_reader->{$method_name}};
    });

    $META->add_method("has_${modifier_type}_method_modifiers" => sub {
        my ($self, $method_name) = @_;
        # NOTE:
        # for now we assume that if it exists,..
        # it has at least one modifier in it
        (exists $self->$attr_reader->{$method_name}) ? 1 : 0;
    });

    $META->add_method("add_${modifier_type}_method_modifier" => sub {
        my ($self, $method_name, $method) = @_;

        $self->$attr_reader->{$method_name} = []
            unless exists $self->$attr_reader->{$method_name};

        my $modifiers = $self->$attr_reader->{$method_name};

        # NOTE:
        # check to see that we aren't adding the
        # same code twice. We err in favor of the
        # first on here, this may not be as expected
        foreach my $modifier (@{$modifiers}) {
            return if $modifier == $method;
        }

        push @{$modifiers} => $method;
    });

}

## ------------------------------------------------------------------
## override method mofidiers

$META->add_attribute('override_method_modifiers' => (
    reader  => 'get_override_method_modifiers_map',
    default => sub { {} }
));

# NOTE:
# these are a little different because there
# can only be one per name, whereas the other
# method modifiers can have multiples.
# - SL

sub add_override_method_modifier {
    my ($self, $method_name, $method) = @_;
    (!$self->has_method($method_name))
        || Moose->throw_error("Cannot add an override of method '$method_name' " .
                   "because there is a local version of '$method_name'");
    $self->get_override_method_modifiers_map->{$method_name} = $method;
}

sub has_override_method_modifier {
    my ($self, $method_name) = @_;
    # NOTE:
    # for now we assume that if it exists,..
    # it has at least one modifier in it
    (exists $self->get_override_method_modifiers_map->{$method_name}) ? 1 : 0;
}

sub get_override_method_modifier {
    my ($self, $method_name) = @_;
    $self->get_override_method_modifiers_map->{$method_name};
}

## general list accessor ...

sub get_method_modifier_list {
    my ($self, $modifier_type) = @_;
    my $accessor = "get_${modifier_type}_method_modifiers_map";
    keys %{$self->$accessor};
}

sub reset_package_cache_flag  { (shift)->{'_package_cache_flag'} = undef }
sub update_package_cache_flag {
    my $self = shift;
    $self->{'_package_cache_flag'} = Class::MOP::check_package_cache_flag($self->name);
}



## ------------------------------------------------------------------
## subroles

__PACKAGE__->meta->add_attribute('roles' => (
    reader  => 'get_roles',
    default => sub { [] }
));

sub add_role {
    my ($self, $role) = @_;
    (blessed($role) && $role->isa('Moose::Meta::Role'))
        || Moose->throw_error("Roles must be instances of Moose::Meta::Role");
    push @{$self->get_roles} => $role;
    $self->reset_package_cache_flag;
}

sub calculate_all_roles {
    my $self = shift;
    my %seen;
    grep {
        !$seen{$_->name}++
    } ($self, map {
                  $_->calculate_all_roles
              } @{ $self->get_roles });
}

sub does_role {
    my ($self, $role_name) = @_;
    (defined $role_name)
        || Moose->throw_error("You must supply a role name to look for");
    # if we are it,.. then return true
    return 1 if $role_name eq $self->name;
    # otherwise.. check our children
    foreach my $role (@{$self->get_roles}) {
        return 1 if $role->does_role($role_name);
    }
    return 0;
}

## ------------------------------------------------------------------
## methods

sub method_metaclass { 'Moose::Meta::Role::Method' }

sub get_method_map {
    my $self = shift;

    my $current = Class::MOP::check_package_cache_flag($self->name);

    if (defined $self->{'_package_cache_flag'} && $self->{'_package_cache_flag'} == $current) {
        return $self->{'methods'} ||= {};
    }

    $self->{_package_cache_flag} = $current;

    my $map  = $self->{'methods'} ||= {};

    my $role_name        = $self->name;
    my $method_metaclass = $self->method_metaclass;

    my $all_code = $self->get_all_package_symbols('CODE');

    foreach my $symbol (keys %{ $all_code }) {
        my $code = $all_code->{$symbol};

        next if exists  $map->{$symbol} &&
                defined $map->{$symbol} &&
                        $map->{$symbol}->body == $code;

        my ($pkg, $name) = Class::MOP::get_code_info($code);

        if ($pkg->can('meta')
            # NOTE:
            # we don't know what ->meta we are calling
            # here, so we need to be careful cause it
            # just might blow up at us, or just complain
            # loudly (in the case of Curses.pm) so we
            # just be a little overly cautious here.
            # - SL
            && eval { no warnings; blessed($pkg->meta) } # FIXME calls meta
            && $pkg->meta->isa('Moose::Meta::Role')) {
            my $role = $pkg->meta->name;
            next unless $self->does_role($role);
        }
        else {
            # NOTE:
            # in 5.10 constant.pm the constants show up 
            # as being in the right package, but in pre-5.10
            # they show up as constant::__ANON__ so we 
            # make an exception here to be sure that things
            # work as expected in both.
            # - SL
            unless ($pkg eq 'constant' && $name eq '__ANON__') {
                next if ($pkg  || '') ne $role_name ||
                        (($name || '') ne '__ANON__' && ($pkg  || '') ne $role_name);
            }            
        }
        
        $map->{$symbol} = $method_metaclass->wrap(
            $code,
            package_name => $role_name,
            name         => $name            
        );
    }

    return $map;    
}

sub get_method { 
    my ($self, $name) = @_;
    $self->get_method_map->{$name};
}

sub has_method {
    my ($self, $name) = @_;
    exists $self->get_method_map->{$name} ? 1 : 0
}

# FIXME this is copy-pasted from Class::MOP::Class
# refactor to inherit from some common base
sub wrap_method_body {
    my ( $self, %args ) = @_;

    ('CODE' eq ref $args{body})
        || Moose->throw_error("Your code block must be a CODE reference");

    $self->method_metaclass->wrap(
        package_name => $self->name,
        %args,
    );
}

sub add_method {
    my ($self, $method_name, $method) = @_;
    (defined $method_name && $method_name)
    || Moose->throw_error("You must define a method name");

    my $body;
    if (blessed($method)) {
        $body = $method->body;
        if ($method->package_name ne $self->name) {
            $method = $method->clone(
                package_name => $self->name,
                name         => $method_name            
            ) if $method->can('clone');
        }
    }
    else {
        $body = $method;
        $method = $self->wrap_method_body( body => $body, name => $method_name );
    }

    $method->attach_to_class($self);

    $self->get_method_map->{$method_name} = $method;

    my $full_method_name = ($self->name . '::' . $method_name);
    $self->add_package_symbol(
        { sigil => '&', type => 'CODE', name => $method_name },
        Class::MOP::subname($full_method_name => $body)
    );

    $self->update_package_cache_flag; # still valid, since we just added the method to the map, and if it was invalid before that then get_method_map updated it
}

sub find_method_by_name { (shift)->get_method(@_) }

sub get_method_list {
    my $self = shift;
    grep { !/^meta$/ } keys %{$self->get_method_map};
}

sub alias_method {
    my $self = shift;

    $self->add_method(@_);
}

## ------------------------------------------------------------------
## role construction
## ------------------------------------------------------------------

sub apply {
    my ($self, $other, @args) = @_;

    (blessed($other))
        || Moose->throw_error("You must pass in an blessed instance");
        
    if ($other->isa('Moose::Meta::Role')) {
        require Moose::Meta::Role::Application::ToRole;
        return Moose::Meta::Role::Application::ToRole->new(@args)->apply($self, $other);
    }
    elsif ($other->isa('Moose::Meta::Class')) {
        require Moose::Meta::Role::Application::ToClass;
        return Moose::Meta::Role::Application::ToClass->new(@args)->apply($self, $other);
    }  
    else {
        require Moose::Meta::Role::Application::ToInstance;
        return Moose::Meta::Role::Application::ToInstance->new(@args)->apply($self, $other);        
    }  
}

sub combine {
    my ($class, @role_specs) = @_;
    
    require Moose::Meta::Role::Application::RoleSummation;
    require Moose::Meta::Role::Composite;  
    
    my (@roles, %role_params);
    while (@role_specs) {
        my ($role, $params) = @{ splice @role_specs, 0, 1 };
        push @roles => $role->meta;
        next unless defined $params;
        $role_params{$role} = $params; 
    }
    
    my $c = Moose::Meta::Role::Composite->new(roles => \@roles);
    Moose::Meta::Role::Application::RoleSummation->new(
        role_params => \%role_params
    )->apply($c);
    
    return $c;
}

sub create {
    my ( $role, $package_name, %options ) = @_;

    $options{package} = $package_name;

    (ref $options{attributes} eq 'HASH')
        || confess "You must pass a HASH ref of attributes"
            if exists $options{attributes};

    (ref $options{methods} eq 'HASH')
        || confess "You must pass a HASH ref of methods"
            if exists $options{methods};

    $role->SUPER::create(%options);

    my (%initialize_options) = %options;
    delete @initialize_options{qw(
        package
        attributes
        methods
        version
        authority
    )};

    my $meta = $role->initialize( $package_name => %initialize_options );

    # FIXME totally lame
    $meta->add_method('meta' => sub {
        $role->initialize(ref($_[0]) || $_[0]);
    });

    if (exists $options{attributes}) {
        foreach my $attribute_name (keys %{$options{attributes}}) {
            my $attr = $options{attributes}->{$attribute_name};
            $meta->add_attribute($attribute_name => $attr);
        }
    }

    if (exists $options{methods}) {
        foreach my $method_name (keys %{$options{methods}}) {
            $meta->add_method($method_name, $options{methods}->{$method_name});
        }
    }

    Class::MOP::weaken_metaclass($meta->name)
        if $meta->is_anon_role;

    return $meta;
}

# anonymous roles. most of it is copied straight out of Class::MOP::Class.
# an intrepid hacker might find great riches if he unifies this code with that
# code in Class::MOP::Module or Class::MOP::Package
{
    # NOTE:
    # this should be sufficient, if you have a
    # use case where it is not, write a test and
    # I will change it.
    my $ANON_ROLE_SERIAL = 0;

    # NOTE:
    # we need a sufficiently annoying prefix
    # this should suffice for now, this is
    # used in a couple of places below, so
    # need to put it up here for now.
    my $ANON_ROLE_PREFIX = 'Moose::Meta::Role::__ANON__::SERIAL::';

    sub is_anon_role {
        my $self = shift;
        no warnings 'uninitialized';
        $self->name =~ /^$ANON_ROLE_PREFIX/;
    }

    sub create_anon_role {
        my ($role, %options) = @_;
        my $package_name = $ANON_ROLE_PREFIX . ++$ANON_ROLE_SERIAL;
        return $role->create($package_name, %options);
    }

    # NOTE:
    # this will only get called for
    # anon-roles, all other calls
    # are assumed to occur during
    # global destruction and so don't
    # really need to be handled explicitly
    sub DESTROY {
        my $self = shift;

        return if Class::MOP::in_global_destruction(); # it'll happen soon anyway and this just makes things more complicated

        no warnings 'uninitialized';
        return unless $self->name =~ /^$ANON_ROLE_PREFIX/;

        # XXX: is this necessary for us? I don't understand what it's doing
        # -sartak

        # Moose does a weird thing where it replaces the metaclass for
        # class when fixing metaclass incompatibility. In that case,
        # we don't want to clean out the namespace now. We can detect
        # that because Moose will explicitly update the singleton
        # cache in Class::MOP.
        #my $current_meta = Class::MOP::get_metaclass_by_name($self->name);
        #return if $current_meta ne $self;

        my ($serial_id) = ($self->name =~ /^$ANON_ROLE_PREFIX(\d+)/);
        no strict 'refs';
        foreach my $key (keys %{$ANON_ROLE_PREFIX . $serial_id}) {
            delete ${$ANON_ROLE_PREFIX . $serial_id}{$key};
        }
        delete ${'main::' . $ANON_ROLE_PREFIX}{$serial_id . '::'};
    }
}

#####################################################################
## NOTE:
## This is Moose::Meta::Role as defined by Moose (plus the use of 
## MooseX::AttributeHelpers module). It is here as a reference to 
## make it easier to see what is happening above with all the meta
## programming. - SL
#####################################################################
#
# has 'roles' => (
#     metaclass => 'Collection::Array',
#     reader    => 'get_roles',
#     isa       => 'ArrayRef[Moose::Meta::Roles]',
#     default   => sub { [] },
#     provides  => {
#         'push' => 'add_role',
#     }
# );
# 
# has 'excluded_roles_map' => (
#     metaclass => 'Collection::Hash',
#     reader    => 'get_excluded_roles_map',
#     isa       => 'HashRef[Str]',
#     provides  => {
#         # Not exactly set, cause it sets multiple
#         'set'    => 'add_excluded_roles',
#         'keys'   => 'get_excluded_roles_list',
#         'exists' => 'excludes_role',
#     }
# );
# 
# has 'attribute_map' => (
#     metaclass => 'Collection::Hash',
#     reader    => 'get_attribute_map',
#     isa       => 'HashRef[Str]',    
#     provides => {
#         # 'set'  => 'add_attribute' # has some special crap in it
#         'get'    => 'get_attribute',
#         'keys'   => 'get_attribute_list',
#         'exists' => 'has_attribute',
#         # Not exactly delete, cause it sets multiple
#         'delete' => 'remove_attribute',    
#     }
# );
# 
# has 'required_methods' => (
#     metaclass => 'Collection::Hash',
#     reader    => 'get_required_methods_map',
#     isa       => 'HashRef[Str]',
#     provides  => {    
#         # not exactly set, or delete since it works for multiple 
#         'set'    => 'add_required_methods',
#         'delete' => 'remove_required_methods',
#         'keys'   => 'get_required_method_list',
#         'exists' => 'requires_method',    
#     }
# );
# 
# # the before, around and after modifiers are 
# # HASH keyed by method-name, with ARRAY of 
# # CODE refs to apply in that order
# 
# has 'before_method_modifiers' => (
#     metaclass => 'Collection::Hash',    
#     reader    => 'get_before_method_modifiers_map',
#     isa       => 'HashRef[ArrayRef[CodeRef]]',
#     provides  => {
#         'keys'   => 'get_before_method_modifiers',
#         'exists' => 'has_before_method_modifiers',   
#         # This actually makes sure there is an 
#         # ARRAY at the given key, and pushed onto
#         # it. It also checks for duplicates as well
#         # 'add'  => 'add_before_method_modifier'     
#     }    
# );
# 
# has 'after_method_modifiers' => (
#     metaclass => 'Collection::Hash',    
#     reader    =>'get_after_method_modifiers_map',
#     isa       => 'HashRef[ArrayRef[CodeRef]]',
#     provides  => {
#         'keys'   => 'get_after_method_modifiers',
#         'exists' => 'has_after_method_modifiers', 
#         # This actually makes sure there is an 
#         # ARRAY at the given key, and pushed onto
#         # it. It also checks for duplicates as well          
#         # 'add'  => 'add_after_method_modifier'     
#     }    
# );
#     
# has 'around_method_modifiers' => (
#     metaclass => 'Collection::Hash',    
#     reader    =>'get_around_method_modifiers_map',
#     isa       => 'HashRef[ArrayRef[CodeRef]]',
#     provides  => {
#         'keys'   => 'get_around_method_modifiers',
#         'exists' => 'has_around_method_modifiers',   
#         # This actually makes sure there is an 
#         # ARRAY at the given key, and pushed onto
#         # it. It also checks for duplicates as well        
#         # 'add'  => 'add_around_method_modifier'     
#     }    
# );
# 
# # override is similar to the other modifiers
# # except that it is not an ARRAY of code refs
# # but instead just a single name->code mapping
#     
# has 'override_method_modifiers' => (
#     metaclass => 'Collection::Hash',    
#     reader    =>'get_override_method_modifiers_map',
#     isa       => 'HashRef[CodeRef]',   
#     provides  => {
#         'keys'   => 'get_override_method_modifier',
#         'exists' => 'has_override_method_modifier',   
#         'add'    => 'add_override_method_modifier', # checks for local method ..     
#     }
# );
#     
#####################################################################


1;

__END__

=pod

=head1 NAME

Moose::Meta::Role - The Moose Role metaclass

=head1 DESCRIPTION

Please see L<Moose::Role> for more information about roles.
For the most part, this has no user-serviceable parts inside
this module. It's API is still subject to some change (although
probably not that much really).

=head1 METHODS

=over 4

=item B<meta>

=item B<new>

=item B<apply>

=item B<apply_to_metaclass_instance>

=item B<combine>

=back

=over 4

=item B<name>

=item B<version>

=item B<role_meta>

=back

=over 4

=item B<get_roles>

=item B<add_role>

=item B<does_role>

=back

=over 4

=item B<add_excluded_roles>

=item B<excludes_role>

=item B<get_excluded_roles_list>

=item B<get_excluded_roles_map>

=item B<calculate_all_roles>

=back

=over 4

=item B<method_metaclass>

=item B<find_method_by_name>

=item B<get_method>

=item B<has_method>

=item B<add_method>

=item B<wrap_method_body>

=item B<alias_method>

=item B<get_method_list>

=item B<get_method_map>

=item B<update_package_cache_flag>

=item B<reset_package_cache_flag>

=back

=over 4

=item B<add_attribute>

=item B<has_attribute>

=item B<get_attribute>

=item B<get_attribute_list>

=item B<get_attribute_map>

=item B<remove_attribute>

=back

=over 4

=item B<add_required_methods>

=item B<remove_required_methods>

=item B<get_required_method_list>

=item B<get_required_methods_map>

=item B<requires_method>

=back

=over 4

=item B<add_after_method_modifier>

=item B<add_around_method_modifier>

=item B<add_before_method_modifier>

=item B<add_override_method_modifier>

=over 4

=back

=item B<has_after_method_modifiers>

=item B<has_around_method_modifiers>

=item B<has_before_method_modifiers>

=item B<has_override_method_modifier>

=over 4

=back

=item B<get_after_method_modifiers>

=item B<get_around_method_modifiers>

=item B<get_before_method_modifiers>

=item B<get_method_modifier_list>

=over 4

=back

=item B<get_override_method_modifier>

=item B<get_after_method_modifiers_map>

=item B<get_around_method_modifiers_map>

=item B<get_before_method_modifiers_map>

=item B<get_override_method_modifiers_map>

=back

=over 4

=item B<create>

=item B<create_anon_role>

=item B<is_anon_role>

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
