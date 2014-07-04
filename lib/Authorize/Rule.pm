package Authorize::Rule;
# ABSTRACT: Rule-based authorization mechanism

use strict;
use warnings;
use Carp       'croak';
use List::Util 'first';

sub new {
    my $class = shift;
    my %opts  = @_;

    defined $opts{'rules'}
        or croak 'You must provide rules';

    return bless {
        default => 0, # deny by default
        %opts,
    }, $class;
}

sub default {
    my $self = shift;
    return $self->{'default'};
}

sub rules {
    my $self = shift;
    return $self->{'rules'};
}

sub is_allowed {
    my $self = shift;
    return $self->allowed(@_)->{'action'};
}

sub allowed {
    my $self         = shift;
    my $entity       = shift;
    my $req_resource = shift;
    my $req_params   = shift || {};
    my $default      = $self->default;
    my $rules        = $self->rules;
    my %result       = (
        entity   => $entity,
        resource => ($req_resource || ''),
        params   => $req_params,
    );

    # deny entities that aren't in the rules
    my $perms = $rules->{$entity}
        or return { %result, action => $default };

    # TODO: allow labels for rules

    # the requested and default
    my @rulesets_pair = (
        $perms->{$req_resource} || [], # rulesets
        $perms->{''}            || [], # rulesets
    );

    # if neither, return default action
    @{ $rulesets_pair[0] } || @{ $rulesets_pair[1] }
        or return { %result, action => $default };

RULESET:
    foreach my $ruleset ( @{ $rulesets_pair[0] }, @{ $rulesets_pair[1] } ) {
        my ( $action, @rules ) = @{$ruleset}
            or next;

        # not accurate because when we move to the second pair (default)
        # it will still increment it instead of clearing it :/
        # need to functionalize this
        $result{'ruleset_idx'}++;
        foreach my $rule (@rules) {
            $result{'rule_idx'}++;
            if ( ref $rule eq 'HASH' ) {
                # check defined params by rule against requested params
                foreach my $key ( keys %{$rule} ) {
                    defined $req_params->{$key}
                        or next RULESET; # no match

                    $req_params->{$key} eq $rule->{$key}
                        or next RULESET; # no match
                }
            } elsif ( ! ref $rule ) {
                defined $req_params->{$rule}
                    or next RULESET; # no match
            } else {
                croak 'Unknown rule type';
            }
        }

        return {
            %result,
            action => $action,
        };
    }

    return { %result, action => $default };
}

1;

__END__

=head1 SYNOPSIS

A simple example:

    my $auth = Authorize::Rule->new(
        rules => {
            # Marge can do everything
            Marge => [ allow => '*' ],

            # Homer can do everything except use the oven
            Homer => [
                deny  => ['oven'],
                allow => '*',
            ],

            # kids can clean and eat at the kitchen
            # but nothing else
            # and they can do whatever they want in their bedroom
            kids => [
                allow => {
                    kitchen => {
                        action => ['eat', 'clean'],
                    },

                    bedroom => '*',
                },

                deny => ['kitchen'],
            ],
        },
    );

    $auth->check( Marge => 'kitchen' ); # 1
    $auth->check( Marge => 'garage'  ); # 1
    $auth->check( Marge => 'bedroom' ); # 1
    $auth->check( Homer => 'oven'    ); # 0
    $auth->check( Homer => 'kitchen' ); # 1

    $auth->check( kids => 'kitchen', { action => 'eat'     } ); # 1
    $auth->check( kids => 'kitchen', { action => 'destroy' } ); # 0

=head1 DESCRIPTION

L<Authorize::Rule> allows you to provide a set of rules for authorizing access
of entities to resources.  This does not cover authentication.
While authentication asks "who are you?", authorization asks "what are you
allowed to do?"

The system is based on decisions per resources and their parameters.

The following two authorization decisions are available:

=over 4

=item * allow

Allow an action.  If something is allowed, B<1> (indicating I<true>) is
returned.

=item * deny

Deny an action.  If something is denied, B<0> (indicating I<false>) is returned.

=back

The following levels of authorization are available:

=over 4

=item * For all resources

Cats think they can do everything.

    my $rules = {
        cats => [ allow => '*' ]
    };

    my $auth = Authorize::Rule->new( rules => $rules );
    $auth->check( cats => 'kitchen' ); # 1, success
    $auth->check( cats => 'bedroom' ); # 1, success

The star (B<*>) character means 'allow/deny all resources to this entity'. By
setting the C<cats> entity to C<allow>, we basically allow cats on all
resources. The resources can be anything such as couch, counter, tables, etc.

If you don't like the example of cats (what's wrong with you?), try to think
of a department (or person) given all access to all resources in your company:

    $rules = {
        syadmins => [ allow => '*' ],
        CEO      => [ allow => '*' ],
    }

=item * Per resource

Dogs, however, provide less of a problem. Mostly if you tell them they aren't
allowed somewhere, they will comply. Dogs can't get on the table. Except the
table, we do want them to have access everywhere.

    $rules = {
        cats => [ allow => '*' ],
        dogs => [
            deny  => ['table'], # they can't go on the table
            allow => '*',       # otherwise, allow everything
        ],
    }

To provide access (allow/deny) to resources, you have specify them as an array.
This helps differ between the star character for 'all'.

Rules are read consecutively and as soon as a rule matches the matching stops.

You can provide multiple resources in a single rule. That way we can ask dogs
to also keep away from the laundry room:

    $rules = {
        cats => [ allow => '*' ],
        dogs => [
            deny  => [ 'table', 'laundry room' ], # they can't go on the table
            allow => '*',                         # otherwise, allow everything
        ],
    }

Suppose we adopted kitties and we want to keep them safe until they grow older,
we keep them in our room and keep others out:

    $rules = {
        cats => [ deny => ['bedroom'], allow => '*' ],
        dogs => [
            deny  => [ 'table', 'laundry room', 'bedroom' ],
            allow => '*',
        ],

        kitties => [
            allow => ['bedroom'],
            deny  => '*',
        ],
    }

A corporate example might refer to some departments (or persons) having access
to some resources while denied everything else, or a certain resource not
available to some while all others are.

    $rules = {
        CEO => [
            deny  => ['Payroll'],
            allow => '*',
        ],

        support => [
            allow => [ 'UserPreferences', 'UserComplaintHistory' ],
            deny  => '*',
        ],
    }

You might ask 'what if there is no last catch-all rule at the end?' - the
answer is that the C<default> clause will be used. You can find an explanation
of it under I<ATTRIBUTES>.

=item * Per resource and per conditions

This is the most extensive control you can have. This allows you to set
permissions based on conditions, such as specific parameters per resource.

The conditions are sent to the C<check> method as additional parameters
and checked against it.

Suppose we have no problem for the dogs to walk on that one table we don't
like?

    my $rules => {
        dogs => [
            allow => {
                table => { owner => ['someone-else'] }
            },

            deny  => ['table'],
            allow => '*',
        ]
    };

    my $auth = Authorize::Rule->new( rules => $rules );
    $auth->check( dogs => 'table', { owner => 'me' } ); # 0, fails

Of course you can use a star (C<*>) as the value which means 'all'.

Since you specify values as an array, you can specify multiple values. They
will each be checked against the value of each hash key. We assume the hash
value for each key is a single string.

Here we specify a list of people whose things we don't mind the dog ruining:

    my $rules => {
        dogs => [
            allow => {
                table => { owner => ['jim', 'john'] }
            },

            deny  => ['table'],
            allow => '*',
        ]
    };

    my $auth = Authorize::Rule->new( rules => $rules );
    $auth->check( dogs => 'table', { owner => 'me'   } ); # 0, fails
    $auth->check( dogs => 'table', { owner => 'jim'  } ); # 1, succeeds
    $auth->check( dogs => 'table', { owner => 'john' } ); # 1, succeeds

=back

More complicated structures (other than hashref of keys to string values)
are currently not supported, though there are plans to add callbacks in
order to allow the user to specify their own checks of conditions.

=head1 ATTRIBUTES

=head2 default

In case there is no matching rule for the entity/resource/conditions, what
would you like to do. The default is to deny (C<0>), but you can change it
to allow by default if there is no match.

    Authorize::Rule->new(
        default => 1, # allow by default
        rules   => {...},
    );

=head2 rules

A hash reference of your permissions.

Top level keys are the entities. This can be groups, users, whichever way you
choose to view it.

    {
        ENTITY => RULES,
    }

For each entity you provide an arrayref of the rules. The will be read and
matched in sequential order. It's good practice to have an explicit last one
as the catch-all for that entity. However, take into account that there is
also the C<default>. By default it will deny unless you change the default
to allow.

    {
        ENTITY => [
            RULE1,
            RULE2,
        ],
    }

Each rule contains a key of the action, either to C<allow> or C<deny>,
followed by a resource definition.

    {
        ENTITY => [
            ACTION => RESOURCE
        ]
    }

You can provide a value of star (C<*>) to say 'this entity can do everything'
or 'this entity cannot do anyting'. You can provide an arrayref of the
resources you want to allow/deny.

    {
        Bender => [
            deny  => [ 'fly ship', 'command team' ],
            allow => '*', # allow everything else
        ],

        Leila => [
            deny  => ['goof off'],
            allow => [ 'fly ship', 'command team' ],
            # if none are matched, it will take the default
        ]
    }

You can also provide conditions as a hashref for each resource. The value
should be either a star (C<*>) to match key existence, or an arrayref to
try and match the value.

    {
        Bender => [
            allow => {
                # must have booze to function
                functioning => { booze => '*' }
            },

            # allow friendship to these people
            allow => {
                friendship => { person => [ 'Leila', 'Fry', 'Amy' ]
            },

            # deny friendship to everyone else
            deny => ['friendship'],
        ]
    }

=head1 METHODS

=head2 check

    $auth->check( ENTITY, RESOURCE );
    $auth->check( ENTITY, RESOURCE, { CONDITIONS } );

You decide what entities and resources you have according to how you define
the rules.

You can think of resources as possible actions on an interface:

    my $auth = Authorize::Rule->new(
        rules => {
            Sawyer => [ allow => [ 'view', 'edit' ] ]
        }
    );

    $auth->check( Sawyer => 'edit' )
        or die 'Sawyer is not allowed to edit';

However, if you have multiple interfaces (which you usually do in more
complicated environments), your resources are those interfaces:

    my $auth = Authorize::Rule->new(
        rules => {
            Sawyer => [ allow => [ 'Dashboard', 'Forum' ] ],
        }
    );

    # can I access the dashboard?
    $auth->check( Sawyer => 'Dashboard' );

That's better. However, it doesn't describe what Sawyer can do in each
resource. This is why you have conditions.

    my $auth = Authorize::Rule->new(
        rules => {
            Sawyer => [
                allow => {
                    Dashboard => { action => ['edit', 'view'] }
                }
            ]
        }
    );

    $auth->check( Sawyer => 'Dashboard', { action => 'delete' } )
        or die 'Stop trying to delete the Dashboard, Sawyer!';

