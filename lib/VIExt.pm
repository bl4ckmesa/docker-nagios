
#
# Copyright 2006 VMware, Inc.  All rights reserved.
#

use 5.006001;
use strict;
use warnings;

our $VERSION = '1.1';

use Archive::Zip qw(:ERROR_CODES);
use URI::URL;
use URI::Escape;

##################################################################################
package VIExt;

#
# Gets the host view. If connecting to virtual center,
# the vihost parameter is used to locate the target host
#
sub get_host_view {
   my ($require_host) = shift;
   my $service_content = Vim::get_service_content();
   my $host_view;
   if ($service_content->about->apiType eq 'VirtualCenter') {
      my $vihost = Opts::get_option('vihost');
      if ($require_host) {
         Opts::assert_usage(defined($vihost), 
                            "The --vihost option must be specified " . 
                            "when connecting to Virtual Center."); 
      }
      return undef unless (defined($vihost));
      $host_view = Vim::find_entity_view(view_type => 'HostSystem', 
                                         filter => {'name' => "^$vihost\$"});
   } else {
      #
      # assume only one entry if connected to an ESX 
      #
      $host_view = Vim::find_entity_view (view_type => 'HostSystem');    
   }
   return $host_view;
}

#
# Displays error, disconnect from server and exit.
#
sub fail {
   my ($msg) = @_;
   print STDERR $msg, "\n";
   Util::disconnect();
   exit(1);
}

#
# Retrieves the file manager.
#
sub get_file_manager {
   my $service_content = Vim::get_service_content();
   my $fm = Vim::get_view (mo_ref => $service_content->{fileManager});
   return $fm;
}

#
# Retrieves the virtual disk manager.
#
sub get_virtual_disk_manager {
   my $service_content = Vim::get_service_content();
   my $fm = Vim::get_view (mo_ref => $service_content->{virtualDiskManager});
   return $fm;
}

#
# Returns the http request created with URL constructed based
# on the path and access mode.
#
sub build_http_request {
   my ($op, $mode, $service_url, $path, $ds, $dc) = @_;

   my $prefix;
   if ($mode eq "folder") {
      $prefix = "/folder";
   } elsif ($mode eq "host") {
      $prefix = "/host";
   } elsif ($mode eq "tmp") {
      $prefix = "/tmp";
   } elsif ($mode eq "docroot") {
      $prefix = "";
   }

   my $url_string;
   
   if ($path =~ /^\/folder/) {
      $url_string = $service_url->scheme . '://' . $service_url->authority . $path;
   } else {
      my @args = ();

      $url_string = $service_url->scheme . '://' . $service_url->authority . $prefix;
      if (defined($path) && $path ne "") {
         $url_string = $url_string . '/' . $path;
      }
      if (defined($ds) && $ds ne "") {
         push(@args, "dsName=$ds");
      }
      if (defined($dc) && $dc ne "") {
         push(@args, "dcPath=$dc");
      }
      if (scalar(@args)) {
         $url_string .= "?" . join('&', @args);
      }
   }

   my $url = URI::URL->new($url_string);

   my $request = HTTP::Request->new($op, $url);
}

sub parse_remote_path {
   my $remote_path = shift;
   my $mode = "folder";
   my $path = "";
   my $ds = "";
   my $dc = "";

   if ($remote_path =~ m@^\s*/host@) {
      $mode = "host";
      if ($remote_path =~ m@^\s*/host/(.*)$@) {
         $path = $1;
      }
   } elsif ($remote_path =~ m@^\s*/tmp@) {
      $mode = "tmp";
      if ($remote_path =~ m@^\s*/tmp/(.*)$@) {
         $path = $1;
      }
   } elsif ($remote_path =~ /\s*\[(.*)\]\s*(.*)$/) {
      $ds = $1;
      $path = $2;
   } elsif ($remote_path =~ m@^\s*/folder/?(.*)\?(.*)@) {
      ($path, my $args) = ($1, $2);
      my @fields = split(/\&/, $args);
      foreach (@fields) {
         if (/dsName=(.*)/) {
            $ds = URI::Escape::uri_unescape($1);
         } elsif (/dcPath=(.*)/) {
            $dc = URI::Escape::uri_unescape($1);
         }
      }
   } else {
      $path = $remote_path;
   }

   return ($mode, $dc, $ds, $path);
}


#
# Transfers a file to the server via http put.
#
sub do_http_put_file {
   my ($user_agent, $request, $file_name) = @_;

   $request->header('Content-Type', 'application/octet-stream');
   $request->header('Content-Length', -s $file_name);
   open(CONTENT, '< :raw', $file_name);
   sub content_source {
      my $buffer;
      my $num_read = read(CONTENT, $buffer, 102400);
      if ($num_read == 0) {
         return "";
      } else {
         return $buffer;
      }
   }

   $request->content(\&content_source);

   my $response;
   $response = $user_agent->request($request);

   close(CONTENT);
}

#
# Retrieves a file from the server via http get.
#
sub do_http_get_file {
   my ($user_agent, $request, $file_name) = @_;
   my $response;
   if (defined($file_name)) {
      $response = $user_agent->request($request, $file_name);
   } else {
      $response = $user_agent->request($request);
   }
   return $response;
}

#
# Unzips a file.
#
sub unzip_file {
   # XXX target_dir not used
   my ($zip_file, $target_dir) = @_;

   my $zip = Archive::Zip->new();

   my $status = $zip->read($zip_file);
   die "Read of $zip_file failed\n" if $status != Archive::Zip::AZ_OK;

   my @members = $zip->memberNames();

   $status  = $zip->extractTree();
   die "Extract of $zip_file failed\n" if $status != Archive::Zip::AZ_OK;

   return \@members;
}

#
# Placeholder for future gpg-based signature verification.
# Currently a no-op.
#
sub verify_signature {
   my ($file, $signature) = @_;
   my $failed = 0;

   unless (-e $file) {
      print "$file does not exist\n";
      $failed = 1;
   }
   unless (-e $signature) {
      print "$signature does not exist\n";
      $failed = 1;
   }
   return 0 if $failed;

   print "  ( skipping verification : $signature )\n";
   return 1;
}

#
# put $local_file into $remote_path of host.
#
sub http_put_file {
   my ($mode, $local_file, $remote_path, $remote_ds, $remote_dc) = @_;

   my $service = Vim::get_vim_service();
   my $service_url = URI::URL->new($service->{vim_soap}->{url});
   my $user_agent = $service->{vim_soap}->{user_agent};

   my $req = build_http_request("PUT", $mode, $service_url, 
                                $remote_path, $remote_ds, $remote_dc);
   unless ($req) {
      print STDERR "Unable to construct request : $remote_path.\n";
   } else {
      do_http_put_file($user_agent, $req, $local_file);
   }
}


#
# put $local_file into $remote_path of host.
# $remote_path is relative path relative to /tmp/
#
sub http_put_tmp_file {
   my ($local_file, $remote_path) = @_;
   http_put_file("tmp", $local_file, $remote_path, undef);
}


# Retrieves content at $remote_path.
# if $local_dest_path is given, also saves content
# to $local_dest_path.
sub http_get_file {
   my ($mode, $remote_path, $remote_ds, $remote_dc, $local_dest_path) = @_;

   my $service = Vim::get_vim_service();
   my $service_url = URI::URL->new($service->{vim_soap}->{url});
   my $user_agent = $service->{vim_soap}->{user_agent};

   my $req = build_http_request("GET", $mode, $service_url, 
                                $remote_path, $remote_ds, $remote_dc);
   unless ($req) {
      print STDERR "Unable to construct request : $remote_path.\n";
   } else {
      my $resp = do_http_get_file($user_agent, $req, $local_dest_path);
      if ($resp) {
         if (!$resp->is_success) {
            print STDERR "GET " . $req->uri . " unsuccessful : " . 
                         $resp->status_line . "\n";
         }
      } else {
         print STDERR "GET " . $req->uri . " unsuccessful : failed to get response\n";
      }
      return $resp;
   }

   return undef;
}

#
# Find the matching option by key
#
sub get_advoption_by_key {
   my ($ao, $key) = @_;

   # convert to dot notation
   $key =~ s/^\s*\///g; 
   $key =~ s/\//\./g; 

   my $optList = $ao->supportedOption();
   foreach my $optDef (@$optList) {
      if ($optDef->key eq $key) {
         my $optList = $ao->setting();
         foreach my $opt (@$optList) {
            if ($opt->key eq $key) {
               return ($optDef, $opt);
            }
         }
      }
   }

   return (undef, undef);
}

#
# Retrieve the type of the option
#
sub get_advoption_type {
   my $optType = shift;
   my $valType = "string"; 

   if (defined($optType)) {
      if ($optType->isa("IntOption")) {
         $valType = "int";
      } elsif ($optType->isa("LongOption")) {
         $valType = "long";
      } elsif ($optType->isa("FloatOption")) {
         $valType = "float";
      } elsif ($optType->isa("BoolOption")) {
         $valType = "boolean";
      }
   }

   return $valType;
}

#
# Sets the default value of the option
#
sub set_advoption_default {
   my ($ao, $key) = @_;
   my ($optDef, $opt) = get_advoption_by_key($ao, $key);
   if (defined($optDef) && defined($opt)) {
      my $valType = get_advoption_type(ref $optDef->optionType);

      my $defVal = $optDef->optionType->defaultValue;
      $defVal = "" unless defined($defVal);

      my $val = new PrimType($defVal, $valType);
      $opt->{value} = $val; 

      $ao->UpdateOptions(changedValue => [$opt]);

      return ($optDef->label, $defVal);
   }
   return (undef, undef);
}

#
# Retrieves the value of the option
#
sub get_advoption {
   my ($ao, $key) = @_;
   my ($optDef, $opt) = get_advoption_by_key($ao, $key);
   if (defined($optDef) && defined($opt)) {
      return ($optDef->label, $opt->value);
   }
   return (undef, undef);
}

#
# Sets the value of the option
#
sub set_advoption {
   my ($ao, $key, $set) = @_;
   my ($optDef, $opt) = get_advoption_by_key($ao, $key);
   if (defined($optDef) && defined($opt)) {
      my $valType = get_advoption_type(ref $optDef->optionType);

      my $val = new PrimType($set, $valType);
      $opt->{value} = $val;

      $ao->UpdateOptions(changedValue => [$opt]);
      return $optDef->label;
   } else {
      return undef;
   }
}
