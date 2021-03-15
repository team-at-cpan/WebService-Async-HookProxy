#!/usr/bin/env perl 
use strict;
use warnings;

use IO::Async::Loop;
use Future::AsyncAwait;
use Future::Utils;
use WebService::Async::HookProxy;
use Net::Async::HTTP;
use Net::Async::WebSocket::Client;

my $loop = IO::Async::Loop->new;
$loop->add(
    my $hook = WebService::Async::HookProxy->new(
    )
);

# Let things start up
await $hook->start;

# Try connecting to it
$loop->add(
    my $ws = Net::Async::WebSocket::Client->new(
        on_text_frame => sub {
            my ($self, $frame) = @_;
            warn "Frame: $frame\n";
        }
    )
);
await $ws->connect(
    url => 'ws://127.0.0.1:8089',
);

# Simulate web hook post
$loop->add(
    my $http = Net::Async::HTTP->new
);

await $http->GET('http://localhost:8088/whatever');

$loop->run;
