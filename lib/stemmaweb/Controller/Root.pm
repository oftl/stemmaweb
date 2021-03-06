package stemmaweb::Controller::Root;
use Moose;
use namespace::autoclean;
use JSON qw ();
use TryCatch;
use XML::LibXML;
use XML::LibXML::XPathContext;


BEGIN { extends 'Catalyst::Controller' }

#
# Sets the actions in this controller to be registered with no prefix
# so they function identically to actions created in MyApp.pm
#
__PACKAGE__->config(namespace => '');

=head1 NAME

stemmaweb::Controller::Root - Root Controller for stemmaweb

=head1 DESCRIPTION

Serves up the main container pages.

=head1 URLs

=head2 index

The root page (/).  Serves the main container page, from which the various
components will be loaded.

=cut

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

	# Are we being asked to load a text immediately? If so 
	if( $c->req->param('withtradition') ) {
		$c->stash->{'withtradition'} = $c->req->param('withtradition');
	}
    $c->stash->{template} = 'index.tt';
}

=head2 about

A general overview/documentation page for the site.

=cut

sub about :Local :Args(0) {
	my( $self, $c ) = @_;
	$c->stash->{template} = 'about.tt';
}

=head2 help/*

A dispatcher for documentation of various aspects of the application.

=cut

sub help :Local :Args(1) {
	my( $self, $c, $topic ) = @_;
	$c->stash->{template} = "$topic.tt";
}

=head1 Elements of index page

=head2 directory

 GET /directory

Serves a snippet of HTML that lists the available texts.  This returns texts belonging to the logged-in user if any, otherwise it returns all public texts.

=cut

sub directory :Local :Args(0) {
	my( $self, $c ) = @_;
    my $m = $c->model('Directory');
    # Is someone logged in?
    my %usertexts;
    if( $c->user_exists ) {
    	my $user = $c->user->get_object;
    	my @list = $m->traditionlist( $user );
    	map { $usertexts{$_->{id}} = 1 } @list;
		$c->stash->{usertexts} = \@list;
		$c->stash->{is_admin} = 1 if $user->is_admin;
	}
	# List public (i.e. readonly) texts separately from any user (i.e.
	# full access) texts that exist. Admin users therefore have nothing
	# in this list.
	my @plist = grep { !$usertexts{$_->{id}} } $m->traditionlist('public');
	$c->stash->{publictexts} = \@plist;
	$c->stash->{template} = 'directory.tt';
}

=head1 AJAX methods for traditions and their properties

=head2 newtradition

 POST /newtradition,
 	{ name: <name>,
 	  language: <language>,
 	  public: <is_public>,
 	  file: <fileupload> }
 
Creates a new tradition belonging to the logged-in user, with the given name
and the collation given in the uploaded file. The file type is indicated via
the filename extension (.csv, .txt, .xls, .xlsx, .xml). Returns the ID and 
name of the new tradition.
 
=cut

sub newtradition :Local :Args(0) {
	my( $self, $c ) = @_;
	return _json_error( $c, 403, 'Cannot save a tradition without being logged in' )
		unless $c->user_exists;

	my $user = $c->user->get_object;
	# Grab the file upload, check its name/extension, and call the
	# appropriate parser(s).
	my $upload = $c->request->upload('file');
	my $name = $c->request->param('name') || 'Uploaded tradition';
	my $lang = $c->request->param( 'language' ) || 'Default';
	my $public = $c->request->param( 'public' ) ? 1 : undef;
	my $direction = $c->request->param('direction') || 'LR';

	my( $ext ) = $upload->filename =~ /\.(\w+)$/;
	my %newopts = (
		'name' => $name,
		'language' => $lang,
		'public' => $public,
		'file' => $upload->tempname,
		'direction' => $direction,
		);

	my $tradition;
	my $errmsg;
	if( $ext eq 'xml' ) {
		my $type;
		# Parse the XML to see which flavor it is.
		my $parser = XML::LibXML->new();
		my $doc;
		try {
			$doc = $parser->parse_file( $newopts{'file'} );
		} catch( $err ) {
			$errmsg = "XML file parsing error: $err";
		}
		if( $doc ) {
			if( $doc->documentElement->nodeName eq 'graphml' ) {
				$type = 'CollateX';
			} elsif( $doc->documentElement->nodeName ne 'TEI' ) {
				$errmsg = 'Unrecognized XML type ' . $doc->documentElement->nodeName;
			} else {
				my $xpc = XML::LibXML::XPathContext->new( $doc->documentElement );
				my $venc = $xpc->findvalue( '/TEI/teiHeader/encodingDesc/variantEncoding/attribute::method' );
				if( $venc && $venc eq 'double-end-point' ) {
					$type = 'CTE';
				} else {
					$type = 'TEI';
				}
			}
		}
		# Try the relevant XML parsing option.
		if( $type ) {
			delete $newopts{'file'};
			$newopts{'xmlobj'} = $doc;
			try {
				$tradition = Text::Tradition->new( %newopts, 'input' => $type );
			} catch ( Text::Tradition::Error $e ) {
				$errmsg = $e->message;
			} catch ( $e ) {
				$errmsg = "Unexpected parsing error: $e";
			}
		}
	} elsif( $ext =~ /^(txt|csv|xls(x)?)$/ ) {
		# If it's Excel we need to pass excel => $ext;
		# otherwise we need to pass sep_char => [record separator].
		if( $ext =~ /xls/ ) {
			$newopts{'excel'} = $ext;
		} else {
			$newopts{'sep_char'} = $ext eq 'txt' ? "\t" : ',';
		}
		try {
			$tradition = Text::Tradition->new( 
				%newopts,
				'input' => 'Tabular',
				);
		} catch ( Text::Tradition::Error $e ) {
			$errmsg = $e->message;
		} catch ( $e ) {
			$errmsg = "Unexpected parsing error: $e";
		}
	} else {
		# Error unless we have a recognized filename extension
		return _json_error( $c, 403, "Unrecognized file type extension $ext" );
	}
	
	# Save the tradition if we have it, and return its data or else the
	# error that occurred trying to make it.
	if( $errmsg ) {
		return _json_error( $c, 500, "Error parsing tradition .$ext file: $errmsg" );
	} elsif( !$tradition ) {
		return _json_error( $c, 500, "No error caught but tradition not created" );
	}

	my $m = $c->model('Directory');
	$user->add_tradition( $tradition );
	my $id = $c->model('Directory')->store( $tradition );
	$c->model('Directory')->store( $user );
	$c->stash->{'result'} = { 'id' => $id, 'name' => $tradition->name };
	$c->forward('View::JSON');
}

=head2 textinfo

 GET /textinfo/$textid
 POST /textinfo/$textid, 
 	{ name: $new_name, 
 	  language: $new_language,
 	  public: $is_public, 
 	  owner: $new_userid } # only admin users can update the owner
 
Returns information about a particular text.

=cut

sub textinfo :Local :Args(1) {
	my( $self, $c, $textid ) = @_;
	my $tradition = $c->model('Directory')->tradition( $textid );
	## Have to keep users in the same scope as tradition
	my $newuser;
	my $olduser;
	unless( $tradition ) {
		return _json_error( $c, 404, "No tradition with ID $textid" );
	}	
	my $ok = _check_permission( $c, $tradition );
	return unless $ok;
	if( $c->req->method eq 'POST' ) {
		return _json_error( $c, 403, 
			'You do not have permission to update this tradition' ) 
			unless $ok eq 'full';
		my $params = $c->request->parameters;
		# Handle changes to owner-accessible parameters
		my $m = $c->model('Directory');
		my $changed;
		# Handle name param - easy
		if( exists $params->{name} ) {
			my $newname = delete $params->{name};
			unless( $tradition->name eq $newname ) {
				try {
					$tradition->name( $newname );
					$changed = 1;
				} catch {
					return _json_error( $c, 500, "Error setting name to $newname: $@" );
				}
			}
		}
		# Handle language param, making Default => null
		my $langval = delete $params->{language} || 'Default';
		
		unless( !$tradition->can('language') || $tradition->language eq $langval ) {
			try {
				$tradition->language( $langval );
				$changed = 1;
			} catch {
				return _json_error( $c, 500, "Error setting language to $langval: $@" );
			}
		}

		# Handle our boolean
		my $ispublic = $tradition->public;
		if( delete $params->{'public'} ) {  # if it's any true value...
			$tradition->public( 1 );
			$changed = 1 unless $ispublic;
		} else {  # the checkbox was unchecked, ergo it should not be public
			$tradition->public( 0 );
			$changed = 1 if $ispublic;
		}
		
		# Handle text direction
		my $tdval = delete $params->{direction} || 'LR';
		
		unless( $tradition->collation->direction
				&& $tradition->collation->direction eq $tdval ) {
			try {
				$tradition->collation->change_direction( $tdval );
				$changed = 1;
			} catch {
				return _json_error( $c, 500, "Error setting direction to $tdval: $@" );
			}
		}
		
		
		# Handle ownership change
		if( exists $params->{'owner'} ) {
			# Only admins can update user / owner
			my $newownerid = delete $params->{'owner'};
			if( $tradition->has_user && !$tradition->user ) {
				$tradition->clear_user;
			}
			unless( !$newownerid || 
				( $tradition->has_user && $tradition->user->email eq $newownerid ) ) {
				unless( $c->user->get_object->is_admin ) {
					return _json_error( $c, 403, 
						"Only admin users can change tradition ownership" );
				}
				$newuser = $m->find_user({ email => $newownerid });
				unless( $newuser ) {
					return _json_error( $c, 500, "No such user " . $newownerid );
				}
				if( $tradition->has_user ) {
					$olduser = $tradition->user;
					$olduser->remove_tradition( $tradition );
				}
				$newuser->add_tradition( $tradition );
				$changed = 1;
			}
		}
		# TODO check for rogue parameters
		if( scalar keys %$params ) {
			my $rogueparams = join( ', ', keys %$params );
			return _json_error( $c, 403, "Request parameters $rogueparams not recognized" );
		}
		# If we safely got to the end, then write to the database.
		$m->save( $tradition ) if $changed;
		$m->save( $newuser ) if $newuser;		
	}

	# Now return the current textinfo, whether GET or successful POST.
	my $textinfo = {
		textid => $textid,
		name => $tradition->name,
		direction => $tradition->collation->direction || 'LR',
		public => $tradition->public || 0,
		owner => $tradition->user ? $tradition->user->email : undef,
		witnesses => [ map { $_->sigil } $tradition->witnesses ],
		# TODO Send them all with appropriate parameters so that the
		# client side can choose what to display.
		reltypes => [ map { $_->name } grep { !$_->is_weak && $_->is_colocation }
			$tradition->collation->relationship_types ]
	};
	## TODO Make these into callbacks in the other controllers maybe?
	if( $tradition->can('language') ) {
		$textinfo->{'language'} = $tradition->language;
	}
	if( $tradition->can('stemweb_jobid') ) {
		$textinfo->{'stemweb_jobid'} = $tradition->stemweb_jobid || 0;
	}
	my @stemmasvg = map { _stemma_info( $_ ) } $tradition->stemmata;
	$textinfo->{stemmata} = \@stemmasvg;
	$c->stash->{'result'} = $textinfo;
	$c->forward('View::JSON');
}

=head2 variantgraph

 GET /variantgraph/$textid
 
Returns the variant graph for the text specified at $textid, in SVG form.

=cut

sub variantgraph :Local :Args(1) {
	my( $self, $c, $textid ) = @_;
	my $tradition = $c->model('Directory')->tradition( $textid );
	unless( $tradition ) {
		return _json_error( $c, 404, "No tradition with ID $textid" );
	}	
	my $ok = _check_permission( $c, $tradition );
	return unless $ok;

	my $collation = $tradition->collation;
	$c->stash->{'result'} = $collation->as_svg;
	$c->forward('View::SVG');
}

sub _stemma_info {
	my( $stemma, $sid ) = @_;
	my $ssvg = $stemma->as_svg();
	$ssvg =~ s/\n/ /mg;
	my $sinfo = {
		name => $stemma->identifier, 
		directed => _json_bool( !$stemma->is_undirected ),
		svg => $ssvg }; 
	if( $sid ) {
		$sinfo->{stemmaid} = $sid;
	}
	return $sinfo;
}

## TODO Separate stemma manipulation functionality into its own controller.
	
=head2 stemma

 GET /stemma/$textid/$stemmaseq
 POST /stemma/$textid/$stemmaseq, { 'dot' => $dot_string }

Returns an SVG representation of the given stemma hypothesis for the text.  
If the URL is called with POST, the stemma at $stemmaseq will be altered
to reflect the definition in $dot_string. If $stemmaseq is 'n', a new
stemma will be added.

=cut

sub stemma :Local :Args(2) {
	my( $self, $c, $textid, $stemmaid ) = @_;
	my $m = $c->model('Directory');
	my $tradition = $m->tradition( $textid );
	unless( $tradition ) {
		return _json_error( $c, 404, "No tradition with ID $textid" );
	}	
	my $ok = _check_permission( $c, $tradition );
	return unless $ok;

	$c->stash->{'result'} = '';
	my $stemma;
	if( $c->req->method eq 'POST' ) {
		if( $ok eq 'full' ) {
			my $dot = $c->request->body_params->{'dot'};
			try {
				if( $stemmaid eq 'n' ) {
					# We are adding a new stemma.
					$stemmaid = $tradition->stemma_count;
					$stemma = $tradition->add_stemma( 'dot' => $dot );
				} elsif( $stemmaid !~ /^\d+$/ ) {
					return _json_error( $c, 403, "Invalid stemma ID specification $stemmaid" );
				} elsif( $stemmaid < $tradition->stemma_count ) {
					# We are updating an existing stemma.
					$stemma = $tradition->stemma( $stemmaid );
					$stemma->alter_graph( $dot );
				} else {
					# Unrecognized stemma ID
					return _json_error( $c, 404, "No stemma at index $stemmaid, cannot update" );
				}
			} catch ( Text::Tradition::Error $e ) {
				return _json_error( $c, 500, $e->message );
			}
			$m->store( $tradition );
		} else {
			# No permissions to update the stemma
			return _json_error( $c, 403, 
				'You do not have permission to update stemmata for this tradition' );
		}
	}
	
	# For a GET or a successful POST request, return the SVG representation
	# of the stemma in question, if any.
	if( !$stemma && $tradition->stemma_count > $stemmaid ) {
		$stemma = $tradition->stemma( $stemmaid );
	}
	# What was requested, XML or JSON?
	my $return_view = 'SVG';
	if( my $accept_header = $c->req->header('Accept') ) {
		$c->log->debug( "Received Accept header: $accept_header" );
		foreach my $type ( split( /,\s*/, $accept_header ) ) {
			# If we were first asked for XML, return SVG
			last if $type =~ /^(application|text)\/xml$/;
			# If we were first asked for JSON, return JSON
			if( $type eq 'application/json' ) {
				$return_view = 'JSON';
				last;
			}
		}
	}
	if( $return_view eq 'SVG' ) {
		$c->stash->{'result'} = $stemma->as_svg();
		$c->forward('View::SVG');
	} else { # JSON
		$c->stash->{'result'} = _stemma_info( $stemma, $stemmaid );
		$c->forward('View::JSON');
	}
}

=head2 stemmadot

 GET /stemmadot/$textid/$stemmaseq
 
Returns the 'dot' format representation of the current stemma hypothesis.

=cut

sub stemmadot :Local :Args(2) {
	my( $self, $c, $textid, $stemmaid ) = @_;
	my $m = $c->model('Directory');
	my $tradition = $m->tradition( $textid );
	unless( $tradition ) {
		return _json_error( $c, 404, "No tradition with ID $textid" );
	}	
	my $ok = _check_permission( $c, $tradition );
	return unless $ok;
	my $stemma = $tradition->stemma( $stemmaid );
	unless( $stemma ) {
		return _json_error( $c, 404, "Tradition $textid has no stemma ID $stemmaid" );
	}
	# Get the dot and transmute its line breaks to literal '|n'
	$c->stash->{'result'} = { 'dot' =>  $stemma->editable( { linesep => '|n' } ) };
	$c->forward('View::JSON');
}

=head2 stemmaroot

 POST /stemmaroot/$textid/$stemmaseq, { root: <root node ID> }

Orients the given stemma so that the given node is the root (archetype). Returns the 
information structure for the new stemma.

=cut 

sub stemmaroot :Local :Args(2) {
	my( $self, $c, $textid, $stemmaid ) = @_;
	my $m = $c->model('Directory');
	my $tradition = $m->tradition( $textid );
	unless( $tradition ) {
		return _json_error( $c, 404, "No tradition with ID $textid" );
	}	
	my $ok = _check_permission( $c, $tradition );
	if( $ok eq 'full' ) {
		my $stemma = $tradition->stemma( $stemmaid );
		try {
			$stemma->root_graph( $c->req->param('root') );
			$m->save( $tradition );
		} catch( Text::Tradition::Error $e ) {
			return _json_error( $c, 400, $e->message );
		} catch {
			return _json_error( $c, 500, "Error re-rooting stemma: $@" );
		}
		$c->stash->{'result'} = _stemma_info( $stemma );
		$c->forward('View::JSON');
	} else {
		return _json_error( $c, 403,  
				'You do not have permission to update stemmata for this tradition' );
	}
}

=head2 download

 GET /download/$textid/$format
 
Returns a file for download of the tradition in the requested format.
 
=cut

sub download :Local :Args(2) {
	my( $self, $c, $textid, $format ) = @_;
	my $tradition = $c->model('Directory')->tradition( $textid );
	unless( $tradition ) {
		return _json_error( $c, 404, "No tradition with ID $textid" );
	}
	my $ok = _check_permission( $c, $tradition );
	return unless $ok;

	my $outmethod = "as_" . lc( $format );
	my $view = "View::$format";
	$c->stash->{'name'} = $tradition->name();
	$c->stash->{'download'} = 1;
	my @outputargs;
	if( $format eq 'SVG' ) {
		# Send the list of colors through to the backend.
		# TODO Think of some way not to hard-code this.
		push( @outputargs, { 'show_relations' => 'all',
			'graphcolors' => [ "#5CCCCC", "#67E667", "#F9FE72", "#6B90D4", 
				"#FF7673", "#E467B3", "#AA67D5", "#8370D8", "#FFC173" ] } );
	}
	try {
		$c->stash->{'result'} = $tradition->collation->$outmethod( @outputargs );
	} catch( Text::Tradition::Error $e ) {
		return _json_error( $c, 500, $e->message );
	}
	$c->forward( $view );
}

####################
### Helper functions
####################

# Helper to check what permission, if any, the active user has for
# the given tradition
sub _check_permission {
	my( $c, $tradition ) = @_;
    my $user = $c->user_exists ? $c->user->get_object : undef;
    if( $user ) {
    	return 'full' if ( $user->is_admin || 
    		( $tradition->has_user && $tradition->user->id eq $user->id ) );
    }
	# Text doesn't belong to us, so maybe it's public?
	return 'readonly' if $tradition->public;

	# ...nope. Forbidden!
	return _json_error( $c, 403, 'You do not have permission to view this tradition.' );
}

# Helper to throw a JSON exception
sub _json_error {
	my( $c, $code, $errmsg ) = @_;
	$c->response->status( $code );
	$c->stash->{'result'} = { 'error' => $errmsg };
	$c->forward('View::JSON');
	return 0;
}

sub _json_bool {
	return $_[0] ? JSON::true : JSON::false;
}

=head2 default

Standard 404 error page

=cut

sub default :Path {
    my ( $self, $c ) = @_;
    $c->response->body( 'Page not found' );
    $c->response->status(404);
}

=head2 end

Attempt to render a view, if needed.

=cut

sub end : ActionClass('RenderView') {}

=head1 AUTHOR

Tara L Andrews

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
