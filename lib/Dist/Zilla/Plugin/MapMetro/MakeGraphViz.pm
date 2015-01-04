package Dist::Zilla::Plugin::MapMetro::MakeGraphViz;
$Dist::Zilla::Plugin::MapMetro::MakeGraphViz::VERSION = '0.1100';
use strict;
use warnings;
use 5.14.0;

use Moose;
use namespace::sweep;
use Path::Tiny;
use MooseX::AttributeShortcuts;
use Types::Standard qw/HashRef ArrayRef Str Maybe/;
use Map::Metro::Shim;
use GraphViz2;

with 'Dist::Zilla::Role::AfterBuild';

has cityname => (
    is => 'rw',
    isa => Maybe[Str],
    predicate => 1,
);

has settings => (
    is => 'rw',
    isa => HashRef,
    traits => ['Hash'],
    init_arg => undef,
    default => sub { { } },
    handles => {
        set_setting => 'set',
        get_setting => 'get',
    },
);
has hidden_positions => (
    is => 'rw',
    isa => ArrayRef,
    traits => ['Array'],
    init_arg => undef,
    default => sub { [] },
    handles => {
        add_hidden => 'push',
        all_hiddens => 'elements',
    },
);


sub after_build {
    my $self = shift;

    if(!$ENV{'MMVIZ'} && !$ENV{'MMVIZDEBUG'}) {
        $self->log('Set either MMVIZ or MMVIZDEBUG to a true value to run this.');
        return;
    }

    my @mapfiles = path('share')->children(qr{map-.*\.metro});
    return if !scalar @mapfiles;

    $self->log('Graphvizing...');

    my $mapfile = shift @mapfiles;
    $mapfile =~ m{map-(.*)\.metro};
    my $map = $1;
    my $graph = Map::Metro::Shim->new(filepath => $mapfile)->parse;

    my $customconnections = {};
    if(path('share/graphviz.conf')->exists) {
        my $settings = path('share/graphviz.conf')->slurp;
        $settings =~  s{^#.*$}{}g;
        $settings =~ s{\n}{ }g;

        foreach my $custom (split m/ +/ => $settings) {
            if($custom =~ m{^(\d+)-(\d+):([\d\.]+)$}) {
                my $origin_station_id = $1;
                my $destination_station_id = $2;
                my $len = $3;

                $self->set_setting(sprintf ('len-%s-%s', $origin_station_id, $destination_station_id), $len);
                $self->set_setting(sprintf ('len-%s-%s', $destination_station_id, $origin_station_id), $len);
            }
            elsif($custom =~ m{^\*(\d+):(-?[\d\.]+,-?[\d\.]+)}) {
                my $station_id = $1;
                my $hidden_station_pos = $2;

                $self->add_hidden({ station_id => $station_id, pos => $hidden_station_pos });
            }
            elsif($custom =~ m{^(\d+):(-?\d+,-?\d+!?)$}) {
                my $station_id = $1;
                my $pos = $2;

                $self->set_setting(sprintf ('pos-%s', $station_id) => $pos);
            }
            elsif($custom =~ m{^!(\d+)-(\d+):(\d+)\^([\d\.]+)$}) {
                my $origin_station_id = $1;
                my $destination_station_id = $2;
                my $connections = $3;
                my $len = $4;

                $customconnections->{ $origin_station_id }{ $destination_station_id } = { connections => $connections, len => $len };
            }
        }
    }

    my $viz = GraphViz2->new(
        global => { directed => 0 },
        graph => { epsilon => 0.00001, fontname => 'sans-serif', fontsize => 100, label => $self->has_cityname ? $self->cityname : ucfirst $map, labelloc => 'top' },
        node => { shape => 'circle', fixedsize => 'true', width => 0.8, height => 0.8, penwidth => 3, fontname => 'sans-serif', fontsize => 20 },
        edge => { penwidth => 5, len => 1.2 },
    );
    foreach my $station ($graph->all_stations) {
        my %pos = $self->get_pos_for($station->id);
        my %node = (name => $station->id, label => $station->id, %pos);
        $viz->add_node(%node);
    }

    foreach my $transfer ($graph->all_transfers) {
        my %len = $self->get_len_for($transfer->origin_station->id, $transfer->destination_station->id);
        $viz->add_edge(from => $transfer->origin_station->id, to => $transfer->destination_station->id, color => '#888888', style => 'dashed', %len);
    }
    foreach my $segment ($graph->all_segments) {
        foreach my $line_id ($segment->all_line_ids) {
            my $color = $graph->get_line_by_id($line_id)->color;
            my $width = $graph->get_line_by_id($line_id)->width;
            my %len = $self->get_len_for($segment->origin_station->id, $segment->destination_station->id);

            $viz->add_edge(from => $segment->origin_station->id,
                           to => $segment->destination_station->id,
                           color => $color,
                           penwidth => $width,
                           %len,
            );
        }
    }
    #* Custom connections (for better visuals)
    my $invisible_station_id = 99000000;
    foreach my $hidden ($self->all_hiddens) {
        $viz->add_node(name => ++$invisible_station_id,
                       label => '',
                       ($ENV{'MMVIZDEBUG'} ? () : (style => 'invis')),
                       width => 0.1,
                       height => 0.1,
                       penwidth => 5,
                       color => '#ff0000',
                       pos => "$hidden->{'pos'}!",
        );
        $viz->add_edge(from => $invisible_station_id,
                       to => $hidden->{'station_id'},
                       color => '#ff0000',
                       penwidth => $ENV{'MMVIZDEBUG'} ? 1 : 0,
                       len => 1,
                       weight => 100,
        );
    }


    foreach my $origin_station_id (keys %{ $customconnections }) {
        foreach my $destination_station_id (keys %{ $customconnections->{ $origin_station_id }}) {
            my $len = $customconnections->{ $origin_station_id }{ $destination_station_id }{'len'};
            my $connection_count = $customconnections->{ $origin_station_id }{ $destination_station_id }{'connections'};

            my $previous_station_id = $origin_station_id;

            foreach my $extra_connection (1 .. $connection_count - 1) {
                $viz->add_node(name => ++$invisible_station_id, label => '', style => 'invis', width => 0.1, height => 0.1, penwidth => 5, color => '#ff0000');

                $viz->add_edge(from => $previous_station_id,
                               to => $invisible_station_id,
                               color => '#ff0000',
                               penwidth => $ENV{'MMVIZDEBUG'} ? 1 : 0,
                               len => $len,
                );

                $previous_station_id = $invisible_station_id;
            }

            $viz->add_edge(from => $previous_station_id,
                           to => $destination_station_id,
                           color => '#ff0000',
                           penwidth => $ENV{'MMVIZDEBUG'} ? 1 : 0,
                           len => $len,
            );
        }
    }

    path('static/images')->mkpath;
    my $file = sprintf('static/images/%s.png', lc $map);
    $viz->run(format => 'png', output_file => $file, driver => 'neato');

    $self->log(sprintf 'Saved in %s.', $file);
}

sub get_len_for {
    my $self = shift;
    my ($origin_station_id, $destination_station_id) = @_;
    return (len => $self->get_setting("len-$origin_station_id-$destination_station_id")) if $self->get_setting("len-$origin_station_id-$destination_station_id");
    return (len => $self->get_setting("len-$origin_station_id-0")) if $self->get_setting("len-$origin_station_id-0");
    return (len => $self->get_setting("len-0-$destination_station_id")) if $self->get_setting("len-0-$destination_station_id");
    return ();
}

sub get_pos_for {
    my $self = shift;
    my $station_id = shift;
    return (pos => $self->get_setting("pos-$station_id")) if $self->get_setting("pos-$station_id");
    return ();
}

1;

__END__

=encoding utf-8

=head1 NAME

Dist::Zilla::Plugin::MapMetro::MakeGraphViz - Automatically creates a GraphViz2 visualisation of a map

=head1 SYNOPSIS

  ;in dist.ini
  [MapMetro::MakeGraphViz]

=head1 DESCRIPTION

This L<Dist::Zilla> plugin creates a L<GraphViz2> visualisation of a L<Map::Metro> map, and is only useful in such a distribution.

=head1 SEE ALSO

L<Map::Metro>

L<Map::Metro::Plugin::Map>

L<Map::Metro::Plugin::Map::Stockholm> - An example

=head1 AUTHOR

Erik Carlsson E<lt>info@code301.comE<gt>

=head1 COPYRIGHT

Copyright 2015 - Erik Carlsson

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
