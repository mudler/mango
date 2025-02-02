use Mojo::Base -strict;

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

use Mango;
use Mojo::IOLoop;
use Mojo::IOLoop::Server;

# Defaults
my $mango = Mango->new;
is_deeply $mango->hosts, [['localhost']], 'right hosts';
is $mango->default_db, 'admin', 'right default database';
is_deeply $mango->credentials, [], 'no credentials';
is $mango->inactivity_timeout, 0,    'right timeout value';
is $mango->j,                  0,    'right j value';
is $mango->w,                  1,    'right w value';
is $mango->wtimeout,           1000, 'right wtimeout value';
is $mango->backlog,            0,    'no operations waiting';

# Simple connection string
$mango = Mango->new('mongodb://127.0.0.1:3000');
is_deeply $mango->hosts, [['127.0.0.1', 3000]], 'right hosts';
is $mango->default_db, 'admin', 'right default database';
is_deeply $mango->credentials, [], 'no credentials';
is $mango->j,        0,    'right j value';
is $mango->w,        1,    'right w value';
is $mango->wtimeout, 1000, 'right wtimeout value';

# Complex connection string
$mango = Mango->new(
  'mongodb://x1:y2@foo.bar:5000,baz:3000/test?journal=1&w=2&wtimeoutMS=2000');
is_deeply $mango->hosts, [['foo.bar', 5000], ['baz', 3000]], 'right hosts';
is $mango->default_db, 'test', 'right default database';
is_deeply $mango->credentials, [[qw(test x1 y2)]], 'right credentials';
is $mango->j,        1,    'right j value';
is $mango->w,        2,    'right w value';
is $mango->wtimeout, 2000, 'right wtimeout value';
is $mango->db->name, 'test', 'right database name';

# Invalid connection string
eval { Mango->new('http://localhost:3000/test') };
like $@, qr/Invalid MongoDB connection string/, 'right error';

# No port
$mango = Mango->new->from_string('mongodb://127.0.0.1,127.0.0.1:5000');
is_deeply $mango->hosts, [['127.0.0.1'], ['127.0.0.1', 5000]], 'right hosts';

# Connection error
my $port = Mojo::IOLoop::Server->generate_port;
eval { Mango->new("mongodb://127.0.0.1:$port/test")->db->command('getnonce') };
ok $@, 'has error';

# Clean up before start
$mango = Mango->new($ENV{TEST_ONLINE});
my $collection = $mango->db->collection('connection_test');
$collection->drop if $collection->options;

# Blocking CRUD
my $oid = $collection->insert({foo => 'bar'});
is $mango->backlog, 0, 'no operations waiting';
isa_ok $oid, 'Mango::BSON::ObjectID', 'right class';
my $doc = $collection->find_one({foo => 'bar'});
is_deeply $doc, {_id => $oid, foo => 'bar'}, 'right document';
$doc->{foo} = 'yada';
is $collection->update({foo => 'bar'}, $doc)->{n}, 1, 'one document updated';
$doc = $collection->find_one($oid);
is_deeply $doc, {_id => $oid, foo => 'yada'}, 'right document';
is $collection->remove->{n}, 1, 'one document removed';

# Non-blocking CRUD
my ($fail, $backlog, $created, $updated, $found, $removed);
my $delay = Mojo::IOLoop->delay(
  sub {
    my $delay = shift;
    $collection->insert({foo => 'bar'} => $delay->begin);
    $backlog = $collection->db->mango->backlog;
  },
  sub {
    my ($delay, $err, $oid) = @_;
    return $delay->pass($err) if $err;
    $created = $oid;
    $collection->find_one({foo => 'bar'} => $delay->begin);
  },
  sub {
    my ($delay, $err, $doc) = @_;
    return $delay->pass($err) if $err;
    $doc->{foo} = 'yada';
    $collection->update(({foo => 'bar'}, $doc) => $delay->begin);
  },
  sub {
    my ($delay, $err, $doc) = @_;
    return $delay->pass($err) if $err;
    $updated = $doc;
    $collection->find_one($created => $delay->begin);
  },
  sub {
    my ($delay, $err, $doc) = @_;
    return $delay->pass($err) if $err;
    $found = $doc;
    $collection->remove($delay->begin);
  },
  sub {
    my ($delay, $err, $doc) = @_;
    $fail    = $err;
    $removed = $doc;
  }
);
$delay->wait;
ok !$fail, 'no error';
is $backlog, 1, 'one operation waiting';
isa_ok $created, 'Mango::BSON::ObjectID', 'right class';
is $updated->{n}, 1, 'one document updated';
is_deeply $found, {_id => $created, foo => 'yada'}, 'right document';
is $removed->{n}, 1, 'one document removed';

# Error in callback
Mojo::IOLoop->singleton->reactor->unsubscribe('error');
$fail = undef;
Mojo::IOLoop->singleton->reactor->once(
  error => sub { $fail .= pop; Mojo::IOLoop->stop });
$collection->insert({foo => 'bar'} => sub { die 'Oops!' });
Mojo::IOLoop->start;
like $fail, qr/Oops!/, 'right error';
is $collection->remove->{n}, 1, 'one document removed';

# Fork safety
$mango      = Mango->new($ENV{TEST_ONLINE});
$collection = $mango->db->collection('connection_test');
my ($connections, $current);
$mango->on(
  connection => sub {
    my ($mango, $id) = @_;
    $connections++;
    $current = $id;
  }
);
is $collection->find->count, 0, 'no documents';
is $connections, 1, 'one connection';
ok $mango->ioloop->stream($current), 'connection exists';
my $last = $current;
is $collection->find->count, 0, 'no documents';
is $connections, 1, 'one connection';
ok $mango->ioloop->stream($current), 'connection exists';
is $last, $current, 'same connection';
{
  local $$ = -23;
  is $collection->find->count, 0, 'no documents';
  is $connections, 2, 'two connections';
  ok $mango->ioloop->stream($current), 'connection exists';
  isnt $last, $current, 'different connections';
  $last = $current;
  is $collection->find->count, 0, 'no documents';
  is $connections, 2, 'two connections';
  ok $mango->ioloop->stream($current), 'connection exists';
  is $last, $current, 'same connection';
}

# Mixed concurrent operations
$collection->insert({test => $_}) for 1 .. 3;
is $mango->backlog, 0, 'no operations waiting';
my @results;
$delay = Mojo::IOLoop->delay(sub { shift; @results = @_ });
$collection->find_one(({test => $_}, {_id => 0}) => $delay->begin) for 1 .. 3;
is $mango->backlog, 3, 'three operations waiting';
is $collection->find_one({test => 1})->{test}, 1, 'right result';
$delay->wait;
is $mango->backlog, 0, 'no operations waiting';
ok !$results[0], 'no error';
is_deeply $results[1], {test => 1}, 'right result';
ok !$results[2], 'no error';
is_deeply $results[3], {test => 2}, 'right result';
ok !$results[4], 'no error';
is_deeply $results[5], {test => 3}, 'right result';
is $collection->remove->{n}, 3, 'three documents removed';

# Fallback server
$mango = Mango->new($ENV{TEST_ONLINE});
$port  = Mojo::IOLoop::Server->generate_port;
unshift @{$mango->hosts}, ['127.0.0.1', $port];
ok $mango->db->command('getnonce')->{nonce}, 'command was successful';
is_deeply $mango->hosts->[0], ['127.0.0.1', $port], 'right server';
ok scalar @{$mango->hosts} > 1, 'more than one server';

# Cleanup before leaving
ok $collection->drop, 'drop connection';

done_testing();
