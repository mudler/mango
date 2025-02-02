use Mojo::Base -strict;

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

use Mango;
use Mango::BSON qw(bson_code bson_dbref);
use Mojo::IOLoop;
use FindBin;
use lib $FindBin::Bin;

# Run command blocking
my $mango = Mango->new($ENV{TEST_ONLINE});
my $db    = $mango->db;
ok $db->command('getnonce')->{nonce}, 'command was successful';

# Run command non-blocking
my ($fail, $result);
$db->command(
  'getnonce' => sub {
    my ($db, $err, $doc) = @_;
    $fail   = $err;
    $result = $doc->{nonce};
    Mojo::IOLoop->stop;
  }
);
Mojo::IOLoop->start;
ok !$fail, 'no error';
ok $result, 'command was successful';

# Memory management
# This test used to fail when $db->mango was weakened
require Other::Module;
ok Other::Module::list_collections(), 'mango was not destroyed';

# Write concern
my $mango2  = Mango->new->w(2)->wtimeout(5000);
my $concern = $mango2->db('test')->build_write_concern;
is $concern->{w},        2,    'right w value';
is $concern->{wtimeout}, 5000, 'right wtimeout value';

# Get database statistics blocking
ok exists $db->stats->{objects}, 'has objects';

# Get database statistics non-blocking
($fail, $result) = ();
$db->stats(
  sub {
    my ($db, $err, $stats) = @_;
    $fail   = $err;
    $result = $stats;
    Mojo::IOLoop->stop;
  }
);
Mojo::IOLoop->start;
ok !$fail, 'no error';
ok exists $result->{objects}, 'has objects';

# Get collection names blocking
my $collection = $db->collection('database_test');
$collection->insert({test => 1});
ok grep { $_ eq 'database_test' } @{$db->collection_names}, 'found collection';
$collection->drop;

# Get collection names non-blocking
$collection->insert({test => 1});
($fail, $result) = ();
$db->collection_names(
  sub {
    my ($db, $err, $names) = @_;
    $fail   = $err;
    $result = $names;
    Mojo::IOLoop->stop;
  }
);
Mojo::IOLoop->start;
ok !$fail, 'no error';
ok grep { $_ eq 'database_test' } @$result, 'found collection';
$collection->drop;

# Dereference blocking
my $oid = $collection->insert({test => 23});
is $db->dereference(bson_dbref('database_test', $oid))->{test}, 23,
  'right result';
$collection->drop;

# Dereference non-blocking
$oid = $collection->insert({test => 23});
($fail, $result) = ();
$db->dereference(
  bson_dbref('database_test', $oid) => sub {
    my ($db, $err, $doc) = @_;
    $fail   = $err;
    $result = $doc;
    Mojo::IOLoop->stop;
  }
);
Mojo::IOLoop->start;
ok !$fail, 'no error';
is $result->{test}, 23, 'right result';
$collection->drop;

# Interrupted blocking command
my $loop = $mango->ioloop;
my $id   = $loop->server((address => '127.0.0.1') => sub { $_[1]->close });
my $port = $loop->acceptor($id)->handle->sockport;
$mango = Mango->new("mongodb://localhost:$port")->ioloop($loop);
eval { $mango->db->command('getnonce') };
like $@, qr/Premature connection close/, 'right error';
$mango->ioloop->remove($id);

# Interrupted non-blocking command
$id = Mojo::IOLoop->server((address => '127.0.0.1') => sub { $_[1]->close });
$port = Mojo::IOLoop->acceptor($id)->handle->sockport;
$mango = Mango->new("mongodb://localhost:$port");
$fail  = undef;
$mango->db->command(
  'getnonce' => sub {
    my ($db, $err) = @_;
    $fail = $err;
    Mojo::IOLoop->stop;
  }
);
Mojo::IOLoop->start;
Mojo::IOLoop->remove($id);
like $fail, qr/Premature connection close/, 'right error';

done_testing();
