
package Moose;

use strict;
use warnings;

use 5.008;

our $VERSION   = '0.64';
$VERSION = eval $VERSION;
our $AUTHORITY = 'cpan:STEVAN';

our $XS_VERSION = $VERSION;

use Scalar::Util 'blessed';
use Carp         'confess', 'croak', 'cluck';

use Moose::Exporter;

use Class::MOP 0.75;

use Moose::Meta::Class;
use Moose::Meta::TypeConstraint;
use Moose::Meta::TypeCoercion;
use Moose::Meta::Attribute;
use Moose::Meta::Instance;

use Moose::Object;

use Moose::Meta::Role;
use Moose::Meta::Role::Composite;
use Moose::Meta::Role::Application;
use Moose::Meta::Role::Application::RoleSummation;
use Moose::Meta::Role::Application::ToClass;
use Moose::Meta::Role::Application::ToRole;
use Moose::Meta::Role::Application::ToInstance;

use Moose::Util::TypeConstraints;
use Moose::Util ();

sub _caller_info {
    my $level = @_ ? ($_[0] + 1) : 2;
    my %info;
    @info{qw(package file line)} = caller($level);
    return \%info;
}

sub throw_error {
    # FIXME This 
    shift;
    goto \&confess
}

sub extends {
    my $class = shift;

    croak "Must derive at least one class" unless @_;

    my @supers = @_;
    foreach my $super (@supers) {
        Class::MOP::load_class($super);
        croak "You cannot inherit from a Moose Role ($super)"
            if $super->can('meta')  && 
               blessed $super->meta &&
               $super->meta->isa('Moose::Meta::Role')
    }



    # this checks the metaclass to make sure
    # it is correct, sometimes it can get out
    # of sync when the classes are being built
    my $meta = Moose::Meta::Class->initialize($class);
    $meta->superclasses(@supers);
}

sub with {
    my $class = shift;
    Moose::Util::apply_all_roles(Class::MOP::Class->initialize($class), @_);
}

sub has {
    my $class = shift;
    my $name  = shift;
    croak 'Usage: has \'name\' => ( key => value, ... )' if @_ == 1;
    my %options = ( definition_context => _caller_info(), @_ );
    my $attrs = ( ref($name) eq 'ARRAY' ) ? $name : [ ($name) ];
    Class::MOP::Class->initialize($class)->add_attribute( $_, %options ) for @$attrs;
}

sub before {
    my $class = shift;
    Moose::Util::add_method_modifier($class, 'before', \@_);
}

sub after {
    my $class = shift;
    Moose::Util::add_method_modifier($class, 'after', \@_);
}

sub around {
    my $class = shift;
    Moose::Util::add_method_modifier($class, 'around', \@_);
}

our $SUPER_PACKAGE;
our $SUPER_BODY;
our @SUPER_ARGS;

sub super {
    # This check avoids a recursion loop - see
    # t/100_bugs/020_super_recursion.t
    return if defined $SUPER_PACKAGE && $SUPER_PACKAGE ne caller();
    return unless $SUPER_BODY; $SUPER_BODY->(@SUPER_ARGS);
}

sub override {
    my $class = shift;
    my ( $name, $method ) = @_;
    Class::MOP::Class->initialize($class)->add_override_method_modifier( $name => $method );
}

sub inner {
    my $pkg = caller();
    our ( %INNER_BODY, %INNER_ARGS );

    if ( my $body = $INNER_BODY{$pkg} ) {
        my @args = @{ $INNER_ARGS{$pkg} };
        local $INNER_ARGS{$pkg};
        local $INNER_BODY{$pkg};
        return $body->(@args);
    } else {
        return;
    }
}

sub augment {
    my $class = shift;
    my ( $name, $method ) = @_;
    Class::MOP::Class->initialize($class)->add_augment_method_modifier( $name => $method );
}

Moose::Exporter->setup_import_methods(
    with_caller => [
        qw( extends with has before after around override augment)
    ],
    as_is => [
        qw( super inner ),
        \&Carp::confess,
        \&Scalar::Util::blessed,
    ],
);

sub init_meta {
    # This used to be called as a function. This hack preserves
    # backwards compatibility.
    if ( $_[0] ne __PACKAGE__ ) {
        return __PACKAGE__->init_meta(
            for_class  => $_[0],
            base_class => $_[1],
            metaclass  => $_[2],
        );
    }

    shift;
    my %args = @_;

    my $class = $args{for_class}
        or Moose->throw_error("Cannot call init_meta without specifying a for_class");
    my $base_class = $args{base_class} || 'Moose::Object';
    my $metaclass  = $args{metaclass}  || 'Moose::Meta::Class';

    Moose->throw_error("The Metaclass $metaclass must be a subclass of Moose::Meta::Class.")
        unless $metaclass->isa('Moose::Meta::Class');

    # make a subtype for each Moose class
    class_type($class)
        unless find_type_constraint($class);

    my $meta;

    if ( $meta = Class::MOP::get_metaclass_by_name($class) ) {
        unless ( $meta->isa("Moose::Meta::Class") ) {
            Moose->throw_error("$class already has a metaclass, but it does not inherit $metaclass ($meta)");
        }
    } else {
        # no metaclass, no 'meta' method

        # now we check whether our ancestors have metaclass, and if so borrow that
        my ( undef, @isa ) = @{ $class->mro::get_linear_isa };

        foreach my $ancestor ( @isa ) {
            my $ancestor_meta = Class::MOP::get_metaclass_by_name($ancestor) || next;

            my $ancestor_meta_class = ($ancestor_meta->is_immutable
                ? $ancestor_meta->get_mutable_metaclass_name
                : ref($ancestor_meta));

            # if we have an ancestor metaclass that inherits $metaclass, we use
            # that. This is like _fix_metaclass_incompatibility, but we can do it now.

            # the case of having an ancestry is not very common, but arises in
            # e.g. Reaction
            unless ( $metaclass->isa( $ancestor_meta_class ) ) {
                if ( $ancestor_meta_class->isa($metaclass) ) {
                    $metaclass = $ancestor_meta_class;
                }
            }
        }

        $meta = $metaclass->initialize($class);
    }

    if ( $class->can('meta') ) {
        # check 'meta' method

        # it may be inherited

        # NOTE:
        # this is the case where the metaclass pragma
        # was used before the 'use Moose' statement to
        # override a specific class
        my $method_meta = $class->meta;

        ( blessed($method_meta) && $method_meta->isa('Moose::Meta::Class') )
            || Moose->throw_error("$class already has a &meta function, but it does not return a Moose::Meta::Class ($meta)");

        $meta = $method_meta;
    }

    unless ( $meta->has_method("meta") ) { # don't overwrite
        # also check for inherited non moose 'meta' method?
        # FIXME also skip this if the user requested by passing an option
        $meta->add_method(
            'meta' => sub {
                # re-initialize so it inherits properly
                $metaclass->initialize( ref($_[0]) || $_[0] );
            }
        );
    }

    # make sure they inherit from Moose::Object
    $meta->superclasses($base_class)
      unless $meta->superclasses();

    return $meta;
}

# This may be used in some older MooseX extensions.
sub _get_caller {
    goto &Moose::Exporter::_get_caller;
}

## make 'em all immutable

$_->make_immutable(
    inline_constructor => 1,
    constructor_name   => "_new",
    # these are Class::MOP accessors, so they need inlining
    inline_accessors => 1
    ) for grep { $_->is_mutable }
    map { $_->meta }
    qw(
    Moose::Meta::Attribute
    Moose::Meta::Class
    Moose::Meta::Instance

    Moose::Meta::TypeCoercion
    Moose::Meta::TypeCoercion::Union

    Moose::Meta::Method
    Moose::Meta::Method::Accessor
    Moose::Meta::Method::Constructor
    Moose::Meta::Method::Destructor
    Moose::Meta::Method::Overriden
    Moose::Meta::Method::Augmented

    Moose::Meta::Role
    Moose::Meta::Role::Method
    Moose::Meta::Role::Method::Required

    Moose::Meta::Role::Composite

    Moose::Meta::Role::Application
    Moose::Meta::Role::Application::RoleSummation
    Moose::Meta::Role::Application::ToClass
    Moose::Meta::Role::Application::ToRole
    Moose::Meta::Role::Application::ToInstance
);

1;

__END__

=pod

=head1 NAME

Moose - A postmodern object system for Perl 5

=head1 SYNOPSIS

  package Point;
  use Moose; # automatically turns on strict and warnings

  has 'x' => (is => 'rw', isa => 'Int');
  has 'y' => (is => 'rw', isa => 'Int');

  sub clear {
      my $self = shift;
      $self->x(0);
      $self->y(0);
  }

  package Point3D;
  use Moose;

  extends 'Point';

  has 'z' => (is => 'rw', isa => 'Int');

  after 'clear' => sub {
      my $self = shift;
      $self->z(0);
  };

=head1 DESCRIPTION

Moose is an extension of the Perl 5 object system.

The main goal of Moose is to make Perl 5 Object Oriented programming
easier, more consistent and less tedious. With Moose you can to think
more about what you want to do and less about the mechanics of OOP.

Additionally, Moose is built on top of L<Class::MOP>, which is a
metaclass system for Perl 5. This means that Moose not only makes
building normal Perl 5 objects better, but it provides the power of
metaclass programming as well.

=head2 New to Moose?

If you're new to Moose, the best place to start is the L<Moose::Intro>
docs, followed by the L<Moose::Cookbook>. The intro will show you what
Moose is, and how it makes Perl 5 OO better.

The cookbook recipes on Moose basics will get you up to speed with
many of Moose's features quickly. Once you have an idea of what Moose
can do, you can use the API documentation to get more detail on
features which interest you.

=head2 Moose Extensions

The C<MooseX::> namespace is the official place to find Moose extensions.
These extensions can be found on the CPAN.  The easiest way to find them
is to search for them (L<http://search.cpan.org/search?query=MooseX::>),
or to examine L<Task::Moose> which aims to keep an up-to-date, easily
installable list of Moose extensions.

=head1 BUILDING CLASSES WITH MOOSE

Moose makes every attempt to provide as much convenience as possible during
class construction/definition, but still stay out of your way if you want it
to. Here are a few items to note when building classes with Moose.

Unless specified with C<extends>, any class which uses Moose will
inherit from L<Moose::Object>.

Moose will also manage all attributes (including inherited ones) that are
defined with C<has>. And (assuming you call C<new>, which is inherited from
L<Moose::Object>) this includes properly initializing all instance slots,
setting defaults where appropriate, and performing any type constraint checking
or coercion.

=head1 PROVIDED METHODS

Moose provides a number of methods to all your classes, mostly through the 
inheritance of L<Moose::Object>. There is however, one exception.

=over 4

=item B<meta>

This is a method which provides access to the current class's metaclass.

=back

=head1 EXPORTED FUNCTIONS

Moose will export a number of functions into the class's namespace which
may then be used to set up the class. These functions all work directly
on the current class.

=over 4

=item B<extends (@superclasses)>

This function will set the superclass(es) for the current class.

This approach is recommended instead of C<use base>, because C<use base>
actually C<push>es onto the class's C<@ISA>, whereas C<extends> will
replace it. This is important to ensure that classes which do not have
superclasses still properly inherit from L<Moose::Object>.

=item B<with (@roles)>

This will apply a given set of C<@roles> to the local class. 

=item B<has $name|@$names =E<gt> %options>

This will install an attribute of a given C<$name> into the current class. If
the first parameter is an array reference, it will create an attribute for
every C<$name> in the list. The C<%options> are the same as those provided by
L<Class::MOP::Attribute>, in addition to the list below which are provided by
Moose (L<Moose::Meta::Attribute> to be more specific):

=over 4

=item I<is =E<gt> 'rw'|'ro'>

The I<is> option accepts either I<rw> (for read/write) or I<ro> (for read
only). These will create either a read/write accessor or a read-only
accessor respectively, using the same name as the C<$name> of the attribute.

If you need more control over how your accessors are named, you can
use the L<reader|Class::MOP::Attribute/reader>,
L<writer|Class::MOP::Attribute/writer> and
L<accessor|Class::MOP::Attribute/accessor> options inherited from
L<Class::MOP::Attribute>, however if you use those, you won't need the
I<is> option.

=item I<isa =E<gt> $type_name>

The I<isa> option uses Moose's type constraint facilities to set up runtime
type checking for this attribute. Moose will perform the checks during class
construction, and within any accessors. The C<$type_name> argument must be a
string. The string may be either a class name or a type defined using
Moose's type definition features. (Refer to L<Moose::Util::TypeConstraints>
for information on how to define a new type, and how to retrieve type meta-data).

=item I<coerce =E<gt> (1|0)>

This will attempt to use coercion with the supplied type constraint to change
the value passed into any accessors or constructors. You B<must> have supplied
a type constraint in order for this to work. See L<Moose::Cookbook::Basics::Recipe5>
for an example.

=item I<does =E<gt> $role_name>

This will accept the name of a role which the value stored in this attribute
is expected to have consumed.

=item I<required =E<gt> (1|0)>

This marks the attribute as being required. This means a I<defined> value must be
supplied during class construction, and the attribute may never be set to
C<undef> with an accessor.

=item I<weak_ref =E<gt> (1|0)>

This will tell the class to store the value of this attribute as a weakened
reference. If an attribute is a weakened reference, it B<cannot> also be
coerced.

=item I<lazy =E<gt> (1|0)>

This will tell the class to not create this slot until absolutely necessary.
If an attribute is marked as lazy it B<must> have a default supplied.

=item I<auto_deref =E<gt> (1|0)>

This tells the accessor whether to automatically dereference the value returned.
This is only legal if your C<isa> option is either C<ArrayRef> or C<HashRef>.

=item I<trigger =E<gt> $code>

The I<trigger> option is a CODE reference which will be called after the value of
the attribute is set. The CODE ref will be passed the instance itself, the
updated value and the attribute meta-object (this is for more advanced fiddling
and can typically be ignored). You B<cannot> have a trigger on a read-only
attribute. 

B<NOTE:> Triggers will only fire when you B<assign> to the attribute,
either in the constructor, or using the writer. Default and built values will
B<not> cause the trigger to be fired.

=item I<handles =E<gt> ARRAY | HASH | REGEXP | ROLE | CODE>

The I<handles> option provides Moose classes with automated delegation features.
This is a pretty complex and powerful option. It accepts many different option
formats, each with its own benefits and drawbacks.

B<NOTE:> The class being delegated to does not need to be a Moose based class,
which is why this feature is especially useful when wrapping non-Moose classes.

All I<handles> option formats share the following traits:

You cannot override a locally defined method with a delegated method; an
exception will be thrown if you try. That is to say, if you define C<foo> in
your class, you cannot override it with a delegated C<foo>. This is almost never
something you would want to do, and if it is, you should do it by hand and not
use Moose.

You cannot override any of the methods found in Moose::Object, or the C<BUILD>
and C<DEMOLISH> methods. These will not throw an exception, but will silently
move on to the next method in the list. My reasoning for this is that you would
almost never want to do this, since it usually breaks your class. As with
overriding locally defined methods, if you do want to do this, you should do it
manually, not with Moose.

You do not I<need> to have a reader (or accessor) for the attribute in order 
to delegate to it. Moose will create a means of accessing the value for you, 
however this will be several times B<less> efficient then if you had given 
the attribute a reader (or accessor) to use.

Below is the documentation for each option format:

=over 4

=item C<ARRAY>

This is the most common usage for I<handles>. You basically pass a list of
method names to be delegated, and Moose will install a delegation method
for each one.

=item C<HASH>

This is the second most common usage for I<handles>. Instead of a list of
method names, you pass a HASH ref where each key is the method name you
want installed locally, and its value is the name of the original method
in the class being delegated to.

This can be very useful for recursive classes like trees. Here is a
quick example (soon to be expanded into a Moose::Cookbook recipe):

  package Tree;
  use Moose;

  has 'node' => (is => 'rw', isa => 'Any');

  has 'children' => (
      is      => 'ro',
      isa     => 'ArrayRef',
      default => sub { [] }
  );

  has 'parent' => (
      is          => 'rw',
      isa         => 'Tree',
      weak_ref => 1,
      handles     => {
          parent_node => 'node',
          siblings    => 'children',
      }
  );

In this example, the Tree package gets C<parent_node> and C<siblings> methods,
which delegate to the C<node> and C<children> methods (respectively) of the Tree
instance stored in the C<parent> slot.

=item C<REGEXP>

The regexp option works very similar to the ARRAY option, except that it builds
the list of methods for you. It starts by collecting all possible methods of the
class being delegated to, then filters that list using the regexp supplied here.

B<NOTE:> An I<isa> option is required when using the regexp option format. This
is so that we can determine (at compile time) the method list from the class.
Without an I<isa> this is just not possible.

=item C<ROLE>

With the role option, you specify the name of a role whose "interface" then
becomes the list of methods to handle. The "interface" can be defined as; the
methods of the role and any required methods of the role. It should be noted
that this does B<not> include any method modifiers or generated attribute
methods (which is consistent with role composition).

=item C<CODE>

This is the option to use when you really want to do something funky. You should
only use it if you really know what you are doing, as it involves manual
metaclass twiddling.

This takes a code reference, which should expect two arguments. The first is the
attribute meta-object this I<handles> is attached to. The second is the
metaclass of the class being delegated to. It expects you to return a hash (not
a HASH ref) of the methods you want mapped.

=back

=item I<metaclass =E<gt> $metaclass_name>

This tells the class to use a custom attribute metaclass for this particular
attribute. Custom attribute metaclasses are useful for extending the
capabilities of the I<has> keyword: they are the simplest way to extend the MOP,
but they are still a fairly advanced topic and too much to cover here, see 
L<Moose::Cookbook::Meta::Recipe1> for more information.

The default behavior here is to just load C<$metaclass_name>; however, we also
have a way to alias to a shorter name. This will first look to see if
B<Moose::Meta::Attribute::Custom::$metaclass_name> exists. If it does, Moose
will then check to see if that has the method C<register_implementation>, which
should return the actual name of the custom attribute metaclass. If there is no
C<register_implementation> method, it will fall back to using
B<Moose::Meta::Attribute::Custom::$metaclass_name> as the metaclass name.

=item I<traits =E<gt> [ @role_names ]>

This tells Moose to take the list of C<@role_names> and apply them to the 
attribute meta-object. This is very similar to the I<metaclass> option, but 
allows you to use more than one extension at a time.

See L<TRAIT NAME RESOLUTION> for details on how a trait name is
resolved to a class name.

Also see L<Moose::Cookbook::Meta::Recipe3> for a metaclass trait
example.

=item I<builder> => Str

The value of this key is the name of the method that will be called to
obtain the value used to initialize the attribute. See the L<builder
option docs in Class::MOP::Attribute|Class::MOP::Attribute/builder>
for more information.

=item I<default> => SCALAR | CODE

The value of this key is the default value which will initialize the attribute.

NOTE: If the value is a simple scalar (string or number), then it can
be just passed as is.  However, if you wish to initialize it with a
HASH or ARRAY ref, then you need to wrap that inside a CODE reference.
See the L<default option docs in
Class::MOP::Attribute|Class::MOP::Attribute/default> for more
information.

=item I<initializer> => Str

This may be a method name (referring to a method on the class with
this attribute) or a CODE ref.  The initializer is used to set the
attribute value on an instance when the attribute is set during
instance initialization (but not when the value is being assigned
to). See the L<initializer option docs in
Class::MOP::Attribute|Class::MOP::Attribute/initializer> for more
information.

=item I<clearer> => Str

Allows you to clear the value, see the L<clearer option docs in
Class::MOP::Attribute|Class::MOP::Attribute/clearer> for more
information.

=item I<predicate> => Str

Basic test to see if a value has been set in the attribute, see the
L<predicate option docs in
Class::MOP::Attribute|Class::MOP::Attribute/predicate> for more
information.

=item I<lazy_build> => (0|1)

Automatically define lazy => 1 as well as builder => "_build_$attr", clearer =>
"clear_$attr', predicate => 'has_$attr' unless they are already defined.


=back

=item B<has +$name =E<gt> %options>

This is variation on the normal attribute creator C<has> which allows you to
clone and extend an attribute from a superclass or from a role. Here is an 
example of the superclass usage:

  package Foo;
  use Moose;

  has 'message' => (
      is      => 'rw',
      isa     => 'Str',
      default => 'Hello, I am a Foo'
  );

  package My::Foo;
  use Moose;

  extends 'Foo';

  has '+message' => (default => 'Hello I am My::Foo');

What is happening here is that B<My::Foo> is cloning the C<message> attribute
from its parent class B<Foo>, retaining the C<is =E<gt> 'rw'> and C<isa =E<gt>
'Str'> characteristics, but changing the value in C<default>.

Here is another example, but within the context of a role:

  package Foo::Role;
  use Moose::Role;

  has 'message' => (
      is      => 'rw',
      isa     => 'Str',
      default => 'Hello, I am a Foo'
  );

  package My::Foo;
  use Moose;

  with 'Foo::Role';

  has '+message' => (default => 'Hello I am My::Foo');

In this case, we are basically taking the attribute which the role supplied 
and altering it within the bounds of this feature. 

Aside from where the attributes come from (one from superclass, the other 
from a role), this feature works exactly the same. This feature is restricted 
somewhat, so as to try and force at least I<some> sanity into it. You are only 
allowed to change the following attributes:

=over 4

=item I<default>

Change the default value of an attribute.

=item I<coerce>

Change whether the attribute attempts to coerce a value passed to it.

=item I<required>

Change if the attribute is required to have a value.

=item I<documentation>

Change the documentation string associated with the attribute.

=item I<lazy>

Change if the attribute lazily initializes the slot.

=item I<isa>

You I<are> allowed to change the type without restriction. 

It is recommended that you use this freedom with caution. We used to 
only allow for extension only if the type was a subtype of the parent's 
type, but we felt that was too restrictive and is better left as a 
policy decision. 

=item I<handles>

You are allowed to B<add> a new C<handles> definition, but you are B<not>
allowed to I<change> one.

=item I<builder>

You are allowed to B<add> a new C<builder> definition, but you are B<not>
allowed to I<change> one.

=item I<metaclass>

You are allowed to B<add> a new C<metaclass> definition, but you are
B<not> allowed to I<change> one.

=item I<traits>

You are allowed to B<add> additional traits to the C<traits> definition.
These traits will be composed into the attribute, but pre-existing traits
B<are not> overridden, or removed.

=back

=item B<before $name|@names =E<gt> sub { ... }>

=item B<after $name|@names =E<gt> sub { ... }>

=item B<around $name|@names =E<gt> sub { ... }>

This three items are syntactic sugar for the before, after, and around method
modifier features that L<Class::MOP> provides. More information on these may be
found in the L<Class::MOP::Class documentation|Class::MOP::Class/"Method
Modifiers"> for now.

=item B<super>

The keyword C<super> is a no-op when called outside of an C<override> method. In
the context of an C<override> method, it will call the next most appropriate
superclass method with the same arguments as the original method.

=item B<override ($name, &sub)>

An C<override> method is a way of explicitly saying "I am overriding this
method from my superclass". You can call C<super> within this method, and
it will work as expected. The same thing I<can> be accomplished with a normal
method call and the C<SUPER::> pseudo-package; it is really your choice.

=item B<inner>

The keyword C<inner>, much like C<super>, is a no-op outside of the context of
an C<augment> method. You can think of C<inner> as being the inverse of
C<super>; the details of how C<inner> and C<augment> work is best described in
the L<Moose::Cookbook::Basics::Recipe6>.

=item B<augment ($name, &sub)>

An C<augment> method, is a way of explicitly saying "I am augmenting this
method from my superclass". Once again, the details of how C<inner> and
C<augment> work is best described in the L<Moose::Cookbook::Basics::Recipe6>.

=item B<confess>

This is the C<Carp::confess> function, and exported here because I use it
all the time. 

=item B<blessed>

This is the C<Scalar::Util::blessed> function, it is exported here because I
use it all the time. It is highly recommended that this is used instead of
C<ref> anywhere you need to test for an object's class name.

=back

=head1 METACLASS TRAITS

When you use Moose, you can also specify traits which will be applied
to your metaclass:

    use Moose -traits => 'My::Trait';

This is very similar to the attribute traits feature. When you do
this, your class's C<meta> object will have the specified traits
applied to it. See L<TRAIT NAME RESOLUTION> for more details.

=head1 TRAIT NAME RESOLUTION

By default, when given a trait name, Moose simply tries to load a
class of the same name. If such a class does not exist, it then looks
for for a class matching
B<Moose::Meta::$type::Custom::Trait::$trait_name>. The C<$type>
variable here will be one of B<Attribute> or B<Class>, depending on
what the trait is being applied to.

If a class with this long name exists, Moose checks to see if it has
the method C<register_implementation>. This method is expected to
return the I<real> class name of the trait. If there is no
C<register_implementation> method, it will fall back to using
B<Moose::Meta::$type::Custom::Trait::$trait> as the trait name.

If all this is confusing, take a look at
L<Moose::Cookbook::Meta::Recipe3>, which demonstrates how to create an
attribute trait.

=head1 UNIMPORTING FUNCTIONS

=head2 B<unimport>

Moose offers a way to remove the keywords it exports, through the C<unimport>
method. You simply have to say C<no Moose> at the bottom of your code for this
to work. Here is an example:

    package Person;
    use Moose;

    has 'first_name' => (is => 'rw', isa => 'Str');
    has 'last_name'  => (is => 'rw', isa => 'Str');

    sub full_name {
        my $self = shift;
        $self->first_name . ' ' . $self->last_name
    }

    no Moose; # keywords are removed from the Person package

=head1 EXTENDING AND EMBEDDING MOOSE

To learn more about extending Moose, we recommend checking out the
"Extending" recipes in the L<Moose::Cookbook>, starting with
L<Moose::Cookbook::Extending::Recipe1>, which provides an overview of
all the different ways you might extend Moose.

=head2 B<< Moose->init_meta(for_class => $class, base_class => $baseclass, metaclass => $metaclass) >>

The C<init_meta> method sets up the metaclass object for the class
specified by C<for_class>. This method injects a a C<meta> accessor
into the class so you can get at this object. It also sets the class's
superclass to C<base_class>, with L<Moose::Object> as the default.

You can specify an alternate metaclass with the C<metaclass> parameter.

For more detail on this topic, see L<Moose::Cookbook::Extending::Recipe2>.

This method used to be documented as a function which accepted
positional parameters. This calling style will still work for
backwards compatibility, but is deprecated.

=head2 B<import>

Moose's C<import> method supports the L<Sub::Exporter> form of C<{into =E<gt> $pkg}>
and C<{into_level =E<gt> 1}>.

B<NOTE>: Doing this is more or less deprecated. Use L<Moose::Exporter>
instead, which lets you stack multiple C<Moose.pm>-alike modules
sanely. It handles getting the exported functions into the right place
for you.

=head2 B<throw_error>

An alias for C<confess>, used by internally by Moose.

=head1 METACLASS COMPATIBILITY AND MOOSE

Metaclass compatibility is a thorny subject. You should start by
reading the "About Metaclass compatibility" section in the
C<Class::MOP> docs.

Moose will attempt to resolve a few cases of metaclass incompatibility
when you set the superclasses for a class, unlike C<Class::MOP>, which
simply dies if the metaclasses are incompatible.

In actuality, Moose fixes incompatibility for I<all> of a class's
metaclasses, not just the class metaclass. That includes the instance
metaclass, attribute metaclass, as well as its constructor class and
destructor class. However, for simplicity this discussion will just
refer to "metaclass", meaning the class metaclass, most of the time.

Moose has two algorithms for fixing metaclass incompatibility.

The first algorithm is very simple. If all the metaclass for the
parent is a I<subclass> of the child's metaclass, then we simply
replace the child's metaclass with the parent's.

The second algorithm is more complicated. It tries to determine if the
metaclasses only "differ by roles". This means that the parent and
child's metaclass share a common ancestor in their respective
hierarchies, and that the subclasses under the common ancestor are
only different because of role applications. This case is actually
fairly common when you mix and match various C<MooseX::*> modules,
many of which apply roles to the metaclass.

If the parent and child do differ by roles, Moose replaces the
metaclass in the child with a newly created metaclass. This metaclass
is a subclass of the parent's metaclass, does all of the roles that
the child's metaclass did before being replaced. Effectively, this
means the new metaclass does all of the roles done by both the
parent's and child's original metaclasses.

Ultimately, this is all transparent to you except in the case of an
unresolvable conflict.

=head2 The MooseX:: namespace

Generally if you're writing an extension I<for> Moose itself you'll want 
to put your extension in the C<MooseX::> namespace. This namespace is 
specifically for extensions that make Moose better or different in some 
fundamental way. It is traditionally B<not> for a package that just happens 
to use Moose. This namespace follows from the examples of the C<LWPx::> 
and C<DBIx::> namespaces that perform the same function for C<LWP> and C<DBI>
respectively.

=head1 CAVEATS

=over 4

=item *

It should be noted that C<super> and C<inner> B<cannot> be used in the same
method. However, they may be combined within the same class hierarchy; see
F<t/014_override_augment_inner_super.t> for an example.

The reason for this is that C<super> is only valid within a method
with the C<override> modifier, and C<inner> will never be valid within an
C<override> method. In fact, C<augment> will skip over any C<override> methods
when searching for its appropriate C<inner>.

This might seem like a restriction, but I am of the opinion that keeping these
two features separate (yet interoperable) actually makes them easy to use, since
their behavior is then easier to predict. Time will tell whether I am right or
not (UPDATE: so far so good).

=back

=head1 ACKNOWLEDGEMENTS

=over 4

=item I blame Sam Vilain for introducing me to the insanity that is meta-models.

=item I blame Audrey Tang for then encouraging my meta-model habit in #perl6.

=item Without Yuval "nothingmuch" Kogman this module would not be possible,
and it certainly wouldn't have this name ;P

=item The basis of the TypeContraints module was Rob Kinyon's idea
originally, I just ran with it.

=item Thanks to mst & chansen and the whole #moose posse for all the
early ideas/feature-requests/encouragement/bug-finding.

=item Thanks to David "Theory" Wheeler for meta-discussions and spelling fixes.

=back

=head1 SEE ALSO

=over 4

=item L<http://www.iinteractive.com/moose>

This is the official web home of Moose, it contains links to our public SVN repo
as well as links to a number of talks and articles on Moose and Moose related
technologies.

=item L<Moose::Cookbook> - How to cook a Moose

=item The Moose is flying, a tutorial by Randal Schwartz

Part 1 - L<http://www.stonehenge.com/merlyn/LinuxMag/col94.html>

Part 2 - L<http://www.stonehenge.com/merlyn/LinuxMag/col95.html>

=item L<Class::MOP> documentation

=item The #moose channel on irc.perl.org

=item The Moose mailing list - moose@perl.org

=item Moose stats on ohloh.net - L<http://www.ohloh.net/projects/moose>

=item Several Moose extension modules in the C<MooseX::> namespace.

See L<http://search.cpan.org/search?query=MooseX::> for extensions.

=back

=head2 Books

=over 4

=item The Art of the MetaObject Protocol

I mention this in the L<Class::MOP> docs too, this book was critical in 
the development of both modules and is highly recommended.

=back

=head2 Papers

=over 4

=item L<http://www.cs.utah.edu/plt/publications/oopsla04-gff.pdf>

This paper (suggested by lbr on #moose) was what lead to the implementation
of the C<super>/C<override> and C<inner>/C<augment> features. If you really
want to understand them, I suggest you read this.

=back

=head1 BUGS

All complex software has bugs lurking in it, and this module is no
exception. If you find a bug please either email me, or add the bug
to cpan-RT.

=head1 FEATURE REQUESTS

We are very strict about what features we add to the Moose core, especially 
the user-visible features. Instead we have made sure that the underlying 
meta-system of Moose is as extensible as possible so that you can add your 
own features easily. That said, occasionally there is a feature needed in the 
meta-system to support your planned extension, in which case you should 
either email the mailing list or join us on irc at #moose to discuss.

=head1 AUTHOR

Moose is an open project, there are at this point dozens of people who have 
contributed, and can contribute. If you have added anything to the Moose 
project you have a commit bit on this file and can add your name to the list.

=head2 CABAL

However there are only a few people with the rights to release a new version 
of Moose. The Moose Cabal are the people to go to with questions regarding
the wider purview of Moose, and help out maintaining not just the code
but the community as well.

Stevan (stevan) Little E<lt>stevan@iinteractive.comE<gt>

Yuval (nothingmuch) Kogman

Shawn (sartak) Moore

Dave (autarch) Rolsky E<lt>autarch@urth.orgE<gt>

=head2 OTHER CONTRIBUTORS

Aankhen

Adam (Alias) Kennedy

Anders (Debolaz) Nor Berle

Nathan (kolibre) Gray

Christian (chansen) Hansen

Hans Dieter (confound) Pearcey

Eric (ewilhelm) Wilhelm

Guillermo (groditi) Roditi

Jess (castaway) Robinson

Matt (mst) Trout

Robert (phaylon) Sedlacek

Robert (rlb3) Boone

Scott (konobi) McWhirter

Shlomi (rindolf) Fish

Chris (perigrin) Prather

Wallace (wreis) Reis

Jonathan (jrockway) Rockway

Piotr (dexter) Roszatycki

Sam (mugwump) Vilain

Cory (gphat) Watson

... and many other #moose folks

=head1 COPYRIGHT AND LICENSE

Copyright 2006-2008 by Infinity Interactive, Inc.

L<http://www.iinteractive.com>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
