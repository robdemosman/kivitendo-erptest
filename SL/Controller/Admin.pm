package SL::Controller::Admin;

use strict;

use parent qw(SL::Controller::Base);

use IO::File;

use SL::DB::AuthUser;
use SL::DB::AuthGroup;
use SL::Helper::Flash;
use SL::Locale::String qw(t8);
use SL::User;

use Rose::Object::MakeMethods::Generic
(
  'scalar --get_set_init' => [ qw(client user nologin_file_name db_cfg all_dateformats all_numberformats all_countrycodes all_stylesheets all_menustyles all_clients all_groups) ],
);

__PACKAGE__->run_before(\&setup_layout);

sub get_auth_level { "admin" };
sub keep_auth_vars {
  my ($class, %params) = @_;
  return $params{action} eq 'login';
}

#
# actions: login, logout
#

sub action_login {
  my ($self) = @_;

  return $self->login_form if !$::form->{do_login};
  return                   if !$self->authenticate_root;
  return                   if !$self->check_auth_db_and_tables;
  return                   if  $self->apply_dbupgrade_scripts;
  $self->redirect_to(action => 'show');
}

sub action_logout {
  my ($self) = @_;
  $::auth->destroy_session;
  $self->redirect_to(action => 'login');
}

#
# actions: creating the authentication database & tables, applying database ugprades
#

sub action_apply_dbupgrade_scripts {
  my ($self) = @_;

  return if $self->apply_dbupgrade_scripts;
  $self->action_show;
}

sub action_create_auth_db {
  my ($self) = @_;

  $::auth->create_database(superuser          => $::form->{db_superuser},
                           superuser_password => $::form->{db_superuser_password},
                           template           => $::form->{db_template});
  $self->check_auth_db_and_tables;
}

sub action_create_auth_tables {
  my ($self) = @_;

  $::auth->create_tables;
  $::auth->set_session_value('admin_password', $::lx_office_conf{authentication}->{admin_password});
  $::auth->create_or_refresh_session;

  my $group = (SL::DB::Manager::AuthGroup->get_all(limit => 1))[0];
  if (!$group) {
    SL::DB::AuthGroup->new(
      name        => t8('Full Access'),
      description => t8('Full access to all functions'),
      rights      => [ map { SL::DB::AuthGroupRight->new(right => $_, granted => 1) } SL::Auth::all_rights() ],
    )->save;
  }

  if (!$self->apply_dbupgrade_scripts) {
    $self->action_login;
  }
}

#
# actions: users
#

sub action_show {
  my ($self) = @_;

  $self->render(
    "admin/show",
    CLIENTS => SL::DB::Manager::AuthClient->get_all_sorted,
    USERS   => SL::DB::Manager::AuthUser->get_all_sorted,
    LOCKED  => (-e $self->nologin_file_name),
    title   => "kivitendo " . t8('Administration'),
  );
}

sub action_new_user {
  my ($self) = @_;

  $self->user(SL::DB::AuthUser->new(
    config_values => {
      vclimit      => 200,
      countrycode  => "de",
      numberformat => "1.000,00",
      dateformat   => "dd.mm.yy",
      stylesheet   => "kivitendo.css",
      menustyle    => "neu",
    },
  ));

  $self->edit_user_form(title => t8('Create a new user'));
}

sub action_edit_user {
  my ($self) = @_;
  $self->edit_user_form(title => t8('Edit User'));
}

sub action_save_user {
  my ($self) = @_;
  my $params = delete($::form->{user})          || { };
  my $props  = delete($params->{config_values}) || { };
  my $is_new = !$params->{id};

  $self->user($is_new ? SL::DB::AuthUser->new : SL::DB::AuthUser->new(id => $params->{id})->load)
    ->assign_attributes(%{ $params })
    ->config_values({ %{ $self->user->config_values }, %{ $props } });

  my @errors = $self->user->validate;

  if (@errors) {
    flash('error', @errors);
    $self->edit_user_form(title => $is_new ? t8('Create a new user') : t8('Edit User'));
    return;
  }

  $self->user->save;

  if ($::auth->can_change_password && $::form->{new_password}) {
    $::auth->change_password($self->user->login, $::form->{new_password});
  }

  flash_later('info', $is_new ? t8('The user has been created.') : t8('The user has been saved.'));
  $self->redirect_to(action => 'show');
}

sub action_delete_user {
  my ($self) = @_;

  if (!$self->user->delete) {
    flash('error', t8('The user could not be deleted.'));
    $self->edit_user_form(title => t8('Edit User'));
    return;
  }

  flash_later('info', t8('The user has been deleted.'));
  $self->redirect_to(action => 'show');
}

#
# actions: locking, unlocking
#

sub action_unlock_system {
  my ($self) = @_;
  unlink $self->nologin_file_name;
  flash_later('info', t8('Lockfile removed!'));
  $self->redirect_to(action => 'show');
}

sub action_lock_system {
  my ($self) = @_;

  my $fh = IO::File->new($self->nologin_file_name, "w");
  if (!$fh) {
    $::form->error(t8('Cannot create Lock!'));

  } else {
    $fh->close;
    flash_later('info', t8('Lockfile created!'));
    $self->redirect_to(action => 'show');
  }
}

#
# initializers
#

sub init_db_cfg            { $::lx_office_conf{'authentication/database'}                                            }
sub init_nologin_file_name { $::lx_office_conf{paths}->{userspath} . '/nologin';                                     }
sub init_client            { SL::DB::AuthClient->new(id => ($::form->{id} || ($::form->{client} || {})->{id}))->load }
sub init_user              { SL::DB::AuthUser  ->new(id => ($::form->{id} || ($::form->{user}   || {})->{id}))->load }
sub init_all_clients       { SL::DB::Manager::AuthClient->get_all_sorted                                             }
sub init_all_groups        { SL::DB::Manager::AuthGroup->get_all_sorted                                              }
sub init_all_dateformats   { [ qw(mm/dd/yy dd/mm/yy dd.mm.yy yyyy-mm-dd)      ]                                      }
sub init_all_numberformats { [ qw(1,000.00 1000.00 1.000,00 1000,00)          ]                                      }
sub init_all_stylesheets   { [ qw(lx-office-erp.css Mobile.css kivitendo.css) ]                                      }
sub init_all_menustyles    {
  return [
    { id => 'old', title => $::locale->text('Old (on the side)') },
    { id => 'v3',  title => $::locale->text('Top (CSS)') },
    { id => 'neu', title => $::locale->text('Top (Javascript)') },
  ];
}

sub init_all_countrycodes {
  my %cc = User->country_codes;
  return [ map { id => $_, title => $cc{$_} }, sort { $cc{$a} cmp $cc{$b} } keys %cc ];
}

#
# filters
#

sub setup_layout {
  my ($self, $action) = @_;

  $::request->layout(SL::Layout::Dispatcher->new(style => 'admin'));
  $::request->layout->use_stylesheet("lx-office-erp.css");
  $::form->{favicon} = "favicon.ico";
}

#
# displaying forms
#

sub login_form {
  my ($self, %params) = @_;
  $::request->layout->focus('#admin_password');
  $self->render('admin/adminlogin', title => t8('kivitendo v#1 administration', $::form->{version}), %params);
}

sub edit_user_form {
  my ($self, %params) = @_;

  $::request->layout->use_javascript("${_}.js") for qw(jquery.selectboxes jquery.multiselect2side);
  $self->render('admin/edit_user', %params);
}

#
# helpers
#

sub check_auth_db_and_tables {
  my ($self) = @_;

  if (!$::auth->check_database) {
    $self->render('admin/check_auth_database', title => t8('Authentification database creation'));
    return 0;
  }

  if (!$::auth->check_tables) {
    $self->render('admin/check_auth_tables', title => t8('Authentification tables creation'));
    return 0;
  }

  return 1;
}

sub apply_dbupgrade_scripts {
  return SL::DBUpgrade2->new(form => $::form, dbdriver => 'Pg', auth => 1)->apply_admin_dbupgrade_scripts(1);
}

sub authenticate_root {
  my ($self) = @_;

  return 1 if $::auth->authenticate_root($::form->{'{AUTH}admin_password'}) == $::auth->OK();

  $::auth->punish_wrong_login;
  $::auth->delete_session_value('admin_password');

  $self->login_form(error => t8('Incorrect Password!'));

  return undef;
}

1;
