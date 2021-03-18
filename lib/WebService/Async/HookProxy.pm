package WebService::Async::HookProxy;
# ABSTRACT: Queue and forward web hook notifications

use strict;
use warnings;

# AUTHORITY
our $VERSION = '0.001';

use Object::Pad;

class WebService::Async::HookProxy extends IO::Async::Notifier;

no indirect qw(fatal);

use curry;
use HTTP::Response;
use Future::AsyncAwait;
use Syntax::Keyword::Try;

use Net::Async::HTTP::Server;
use Net::Async::WebSocket::Server;
use Routes::Tiny;

use Future::Utils qw(fmap_void);

use JSON::MaybeUTF8 qw(:v1);
use Log::Any qw($log);

# Default listening ports
has $http_port = 8088;
has $ws_port = 8089;

# Number of requests we can keep around before we start throwing things away
has $max_queued = 1000;

# Our Net::Async::HTTP::Server instance for listening to incoming requests
has $http;
# The websockets server for passing queued requests back to listeners
has $ws;

# Any pending messages to deliver to clients (will accumulate while
# no clients are connected)
has @pending;

# This is active while sending queued items to waiting clients
has $client_processing;

# The websocket clients to whom messages should be delivered
has @clients;

# Our HTTP server instance
method http { $http }

# Our websocket server instance
method ws { $ws }

# Receives a Net::Async::HTTP::Server::Request for each webhook post
method incoming_webhook ($req) {
    my $content_type = $req->header('Content-Type');
    my $content = $content_type ? $req->body : undef;
    my $json = $content_type =~ /javascript|json/
        ? decode_json_utf8($content)
        : undef;

    my $data = {
        method => $req->method,
        host => $req->header('Host'),
        path => $req->path,
        query => { $req->query_form },
        headers => {
            map { @$_ } $req->headers,
        },
        content => $content,
        json => $json,
    };

    $log->debugf('Received webhook notification %s', $data);

    $self->queue_notification($data);

    # Reply immediately
    $req->respond(HTTP::Response->new(200, 'OK', [
        'Content-Length' => '0',
    ], ''));
}

=head2 queue_notification

Record an incoming notification in our queue.

This might trigger client processing as well: if we have any clients
registered, we'll start sending. If not, we just queue.

=cut

method queue_notification ($data) {
    splice @pending, 0, @pending - $max_queued if @pending >= $max_queued;

    push @pending, $data;

    # No point trying to notify if no one is connected
    return unless @clients;

    $client_processing ||= (fmap_void {
        my ($item) = @_;
        return $self->notify_clients($item);
    } foreach => \@pending, concurrent => 1)->on_ready($self->$curry::weak(method {
        undef $client_processing
    }));
}

=head2 notify_clients

Send out notifications to all clients.

This will loop around the known clients, sending the same item to each.

=cut

async method notify_clients ($item) {
    my $data = encode_json_utf8($item);
    await (fmap_void(sub {
        my ($client) = @_;
        return $self->notify_client($client => $data);
    }, foreach => [ @clients ], concurrent => 4));
}

=head2 notify_client

Notify a single client.

Takes a client and UTF-8 binary data to send them, and delivers the
websocket notification to them.

=cut

async method notify_client ($client, $data) {
    await $client->send_frame(
        buffer => $data,
        masked => 1,
    );
}

=head2 incoming_client

Register the given client: called when we have a new websocket connection.

=cut

method incoming_client ($client) {
    $log->infof('Received websocket client');
    push @clients, $client;
}

async method start {
    $self->add_child(
        $http = Net::Async::HTTP::Server->new(
            on_request => $self->$curry::weak(method ($notifier, $req) {
                $self->incoming_webhook($req)
            }),
        )
    );
    $self->add_child(
        $ws = Net::Async::WebSocket::Server->new(
            on_client => $self->$curry::weak(method ($notifier, $client) {
                $self->incoming_client($client)
            }),
        )
    );

    # Ideally these would both listen on the same port, but typically we're running
    # in a proxy situation anyway, so nginx or equivalent would handle this for us.
    my ($http_listener, $ws_listener) = await Future->needs_all(
        $self->http->listen(
            socktype => 'stream',
            service => 8088,
        ),
        $self->ws->listen(
            service => 8089,
        )
    );
}

method configure (%args) {
    $http_port = delete $args{http_port} if exists $args{http_port};
    $ws_port = delete $args{ws_port} if exists $args{ws_port};
    $max_queued = delete $args{max_queued} if exists $args{max_queued};
    return $self->next::method(%args);
}

1;

