use strict;
use warnings;

use POSIX qw< dup dup2 >;
use Devel::Peek;
use Data::Dumper;
use Test::More;
use JavaScript::Duktape::XS;

sub test_simple {
    my $duk = JavaScript::Duktape::XS->new();
    ok($duk, "created JavaScript::Duktape::XS object");

    my %values = (
        foo => "2+3*4",
        'aref' => [2,3,4],
        'aref aref' => [2, [3,4], 5 ],
        'href' => { foo => 1 },
        'href' => { foo => [1,2,[3,4,5]] },
        'aref href' => [2, { foo => 1 } ],
        'href aref' => { foo => [2] },
        'aref href' => [{ 1 => 2 }],
        'aref large' => [2, 4, [ 1, 3], [ [5, 7], 9 ] ],
        'href large' => { 'one' => [ 1, 2, { foo => 'bar'} ], 'two' => { baz => [3, 2]} },
        'gonzo' => sub { print("HOI\n"); },
    );
    foreach my $name (sort keys %values) {
        my $expected = $values{$name};
        $duk->set($name, $expected);
        my $got = $duk->get($name);
        is_deeply($got, $expected, "set and got [$name]")
            or printf STDERR ("%s", Dumper({got => $got, expected => $expected}));
    }
}

sub test_set_get {
    my $duk = JavaScript::Duktape::XS->new();
    ok($duk, "created JavaScript::Duktape::XS object");

    my %values = (
        'undef'  => undef,
        '0' => 0,
        '1' => 1,
        '0.0' => 0.0,
        'pi' => 3.1416,
        'empty'  => '',
        'string'  => 'gonzo',
        'aref empty' => [],
        'aref ints' => [5, 6, 7],
        'aref mixed' => [1, 0, 'gonzo'],
        'href empty' => {},
        'href simple' => { 'one' => 1, 'two' => 2 },
        'gonzo' => sub { print("HOI\n"); },
    );
    foreach my $name (sort keys %values) {
        my $expected = $values{$name};
        $duk->set($name, $expected);
        my $got = $duk->get($name);
        is_deeply($got, $expected, "set and got [$name]")
            or printf STDERR ("%s", Dumper({got => $got, expected => $expected}));
    }
}

sub test_eval {
    my $duk = JavaScript::Duktape::XS->new();
    ok($duk, "created JavaScript::Duktape::XS object");

    my $callback = sub {
        printf("HOI [%s]\n", join(",", map +(defined $_ ? $_ : "UNDEF"), @_));
        return scalar @_;
    };
    $duk->set('gonzo' => $callback);
    my @commands = (
        [ "'gonzo'" => 'gonzo' ],
        [ "3+4*5"   => 23 ],
        [ "true"    => 1 ],
        [ "null"    => undef ],
        [ "say('Hello world from Javascript!');" => undef, 'Hello world from Javascript!' ],
        [ "say(2+3*4)" => undef, '14' ],
        [ 'gonzo()' => 0, 'HOI []' ],
        [ 'gonzo(1)' => 1, 'HOI [1]' ],
        [ 'gonzo("a", "b")' => 2, 'HOI [a,b]' ],
        [ 'gonzo("a", 1, null, "b")' => 4, 'HOI [a,1,UNDEF,b]' ],
    );

    foreach my $cmd (@commands) {
        my ($js, $expected_return, $expected_output) = @$cmd;
        $expected_output //= '';
        my $output = '';

        # Move STDOUT to store results in $output
        my $real_stdout;
        open $real_stdout, ">&STDOUT" || warn "Can't preserve STDOUT\n$!\n";
        close STDOUT;
        open STDOUT, '>', \$output or die "Can't open STDOUT: $!";
        select STDOUT; $| = 1;

        my $got = $duk->eval($js);

        # Now recover original STDOUT
        close STDOUT;
        open STDOUT, ">&", $real_stdout;
        select STDOUT; $| = 1;

        chomp($output);
        is($output, $expected_output, "eval output [$js]");
        is_deeply($got, $expected_return, "eval return [$js]");
    }
}

sub test_roundtrip {
    my $duk = JavaScript::Duktape::XS->new();
    ok($duk, "created JavaScript::Duktape::XS object");

    my $test_name;
    my $expected_args;
    my $callback = sub {
        is_deeply(\@_, $expected_args, "expected args $test_name")
            or printf STDERR Dumper({ got => \@_, expected => $expected_args });
        return $expected_args;
    };
    $duk->set('perl_test' => $callback);
    my %args = (
        'empty' => [ [], '' ],
        'undef' => [ [undef], 'null' ],
        'one number' => [ [1], '1' ],
        'two strings' => [ ['a','b'], q{'a','b'} ],
        'nested aref' => [ [ [ 1, 2, [ 3, [], { foo => [5, 6] } ], [8] ] ],
                           q{[1,2,[3,[],{"foo":[5,6]}],[8]]} ],
        'nested href' => [ [ { foo => 1, bar => [4,[],5,{},{baz=>3}] } ],
                           q<{"foo":1,"bar":[4,[],5,{},{"baz":3}]}> ],
    );
    foreach my $name (sort keys %args) {
        my ($perl_args, $js_args) = @{ $args{$name} };
        $test_name = $name;
        $expected_args = $perl_args;
        my $got = $duk->eval("perl_test($js_args)");
        is_deeply($got, $perl_args, "got args $name");
    }
}

sub main {
    test_simple();
    test_set_get();
    test_eval();
    test_roundtrip();
    done_testing;
    return 0;
}

exit main();
