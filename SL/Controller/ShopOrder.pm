package SL::Controller::ShopOrder;

use strict;

use parent qw(SL::Controller::Base);

use SL::BackgroundJob::ShopOrderMassTransfer;
use SL::System::TaskServer;
use SL::DB::ShopOrder;
use SL::DB::ShopOrderItem;
use SL::DB::Shop;
use SL::Shop;
use SL::Presenter;
use SL::Helper::Flash;
use SL::Locale::String;
use SL::Controller::Helper::ParseFilter;
use Rose::Object::MakeMethods::Generic
(
  'scalar --get_set_init' => [ qw(shop_order transferred js) ],
);

__PACKAGE__->run_before('setup');

use Data::Dumper;

sub action_get_orders {
  my ( $self ) = @_;

  my $active_shops = SL::DB::Manager::Shop->get_all(query => [ obsolete => 0 ]);
  foreach my $shop_config ( @{ $active_shops } ) {
    my $shop = SL::Shop->new( config => $shop_config );
    my $new_orders = $shop->connector->get_new_orders;
  };
  $self->action_list;
}

sub action_list {
  my ( $self ) = @_;
  my %filter = ($::form->{filter} ? parse_filter($::form->{filter}) : query => [ transferred => 0 ]);
  my $transferred = $::form->{filter}->{transferred_eq_ignore_empty} ne '' ? $::form->{filter}->{transferred_eq_ignore_empty} : '';
  my $sort_by = $::form->{sort_by} ? $::form->{sort_by} : 'order_date';
  $sort_by .=$::form->{sort_dir} ? ' DESC' : ' ASC';
  my $shop_orders = SL::DB::Manager::ShopOrder->get_all( %filter, sort_by => $sort_by,
                                                      with_objects => ['shop_order_items'],
                                                    );
  foreach my $shop_order ( @$shop_orders ) {
    my %billing_address = ( 'name'     => $shop_order->billing_lastname,
                            'company'  => $shop_order->billing_company,
                            'street'   => $shop_order->billing_street,
                            'zipcode'  => $shop_order->billing_zipcode,
                            'city'     => $shop_order->billing_city,
                          );
    my $b_address = $self->check_address(%billing_address);
    if ($b_address) {
      $shop_order->{kivi_customer_id} = $b_address->{id};
      $shop_order->save;
    }
    $shop_order->{kivi_cv_id} = $b_address;
  }
  $self->render('shop_order/list',
                title       => t8('ShopOrders'),
                SHOPORDERS  => $shop_orders,
                TOOK        => $transferred,  # is this used?
              );
}

sub action_show {
  my ( $self ) = @_;
  my $id = $::form->{id} || {};
  my $shop_order = SL::DB::Manager::ShopOrder->find_by( id => $id );
  die "can't find shoporder with id $id" unless $shop_order;
  # the different importaddresscheck if there complete in the customer table to prevent duplicats inserts
  my %customer_address = ( 'name'    => $shop_order->customer_lastname,
                           'company' => $shop_order->customer_company,
                           'street'  => $shop_order->customer_street,
                           'zipcode' => $shop_order->customer_zipcode,
                           'city'    => $shop_order->customer_city,
                         );
  my %billing_address = ( 'name'     => $shop_order->billing_lastname,
                          'company'  => $shop_order->billing_company,
                          'street'   => $shop_order->billing_street,
                          'zipcode'  => $shop_order->billing_zipcode,
                          'city'     => $shop_order->billing_city,
                        );
  my %delivery_address = ( 'name'    => $shop_order->delivery_lastname,
                           'company' => $shop_order->delivery_company,
                           'street'  => $shop_order->delivery_street,
                           'zipcode' => $shop_order->delivery_zipcode,
                           'city'    => $shop_order->delivery_city,
                         );
  my $c_address = $self->check_address(%customer_address);
  my $b_address = $self->check_address(%billing_address);
  my $d_address = $self->check_address(%delivery_address);
  ####

  my $lastname = $shop_order->customer_lastname;
  $main::lxdebug->message(0, "WH: HIER");
  my $proposals = SL::DB::Manager::Customer->get_all(
       where => [
                   or => [
                            and => [ # when matching names also match zipcode
                                     or => [ 'name' => { like => "%$lastname%"},
                                             'name' => { like => $shop_order->customer_company },
                                           ],
                                     'zipcode' => { like => $shop_order->customer_zipcode },
                                   ],
                            or  => [ 'email' => { like => $shop_order->customer_email } ],
                         ],
                ],
  );

  $self->render('shop_order/show',
                title       => t8('Shoporder'),
                IMPORT      => $shop_order,
                PROPOSALS   => $proposals,
                C_ADDRESS   => $c_address,
                B_ADDRESS   => $b_address,
                D_ADDRESS   => $d_address,
              );

}

sub action_transfer {
  my ( $self ) = @_;
  my $customer = SL::DB::Manager::Customer->find_by(id => $::form->{customer});
  die "Can't find customer" unless $customer;
  my $employee = SL::DB::Manager::Employee->current;

  # $self->shop_order inits via $::form->{import_id}
  die "Can't load shop_order form form->import_id" unless $self->shop_order;

  my $order = $self->shop_order->convert_to_sales_order(customer => $customer, employee => $employee);
  $order->save;
  $self->shop_order->transferred(1);
  $self->shop_order->transfer_date(DateTime->now_local);
  $self->shop_order->oe_transid($order->id);
  $self->shop_order->save;
  $self->shop_order->link_to_record($order);
  $self->redirect_to(controller => "oe.pl", action => 'edit', type => 'sales_order', vc => 'customer', id => $order->id);
}

sub action_mass_transfer {
  my ($self) = @_;
  my @shop_orders =  @{ $::form->{id} || [] };
  $::lxdebug->dump(0, 'WH: MT II', \@shop_orders);
  $::lxdebug->dump(0, 'WH: MT SELF', \$self);
  $::lxdebug->dump(0, 'WH: MT FORM', \$::form);

  my $job                   = SL::DB::BackgroundJob->new(
    type                    => 'once',
    active                  => 1,
    package_name            => 'ShopOrderMassTransfer',
  )->set_data(
     shop_order_record_ids       => [ @shop_orders ],
     num_order_created           => 0,
     num_delivery_order_created  => 0,
     status                      => SL::BackgroundJob::ShopOrderMassTransfer->WAITING_FOR_EXECUTION(),
     conversation_errors         => [ ],
   )->update_next_run_at;

   SL::System::TaskServer->new->wake_up;

   my $html = $self->render('shop_order/_transfer_status', { output => 0 }, job => $job);

$main::lxdebug->dump(0, 'WH: iHTML: ',\$html);
   $self->js
      ->html('#status_mass_transfer', $html)
      ->run('kivi.ShopOrder.massTransferStarted')
      ->render;
}

sub action_transfer_status {
  my ($self)  = @_;
  $main::lxdebug->dump(0, 'WH: STATUS1 ',\$self);
  $main::lxdebug->dump(0, 'WH: STATUS2 ',\$::form);
  my $job     = SL::DB::BackgroundJob->new(id => $::form->{job_id})->load;
  my $html    = $self->render('shop_order/_transfer_status', { output => 0 }, job => $job);

  $self->js->html('#status_mass_transfer', $html);
  $self->js->run('kivi.ShopOrder.massTransferFinished') if $job->data_as_hash->{status} == SL::BackgroundJob::ShopOrderMassTransfer->DONE();
  $self->js->render;

}
sub action_apply_customer {
  my ( $self ) = @_;
  my $what = $::form->{create_customer}; # billing, customer or delivery
  my %address = ( 'name'       => $::form->{$what.'_name'},
                  'street'     => $::form->{$what.'_street'},
                  'zipcode'    => $::form->{$what.'_zipcode'},
                  'city'       => $::form->{$what.'_city'},
                  'email'      => $::form->{$what.'_email'},
                  'country'    => $::form->{$what.'_country'},
                  'greeting'   => $::form->{$what.'_greeting'},
                  'taxzone_id' => 4,  # hardcoded, use default taxzone instead
                  'currency'   => 1,  # hardcoded
                );
  $address{contact} = ($address{name} ne $::form->{$what.'_firstname'} . " " . $::form->{$what.'_lastname'} ? $::form->{$what.'_firstname'} . " " . $::form->{$what.'_lastname'} : '');
  my $customer = SL::DB::Customer->new(%address);
  $customer->save;
  if($::form->{$what.'_country'} ne "Deutschland") {   # hardcoded
    $self->redirect_to(controller => "controller.pl", action => 'CustomerVendor/edit', id => $customer->id);
  }else{
    $self->redirect_to(action => 'show', id => $::form->{import_id});
  }
}

sub setup {
  my ($self) = @_;
  $::auth->assert('invoice_edit');

  $::request->layout->use_javascript("${_}.js")  for qw(kivi.ShopOrder);
}

#
# Helper
#
sub check_address {
  my ($self,%address) = @_;
  my $addressdata = SL::DB::Manager::Customer->get_all(
                                query => [
                                            or => [ 'name'   => { like => "%$address{'name'}%" }, 'name' => { like => $address{'company'} }, ],
                                           'street' => { like => $address{'street'} },
                                           'zipcode'=> { like => $address{'zipcode'} },
                                           'city'   => { like => $address{'city'} },
                                         ]);
  return @{$addressdata}[0];
}

sub init_shop_order {
  my ( $self ) = @_;
  return SL::DB::ShopOrder->new(id => $::form->{import_id})->load if $::form->{import_id};
}

sub init_transferred {
  # data for drop down filter options

  [ { title => t8("all"),             value => '' },
    { title => t8("transferred"),     value => 1  },
    { title => t8("not transferred"), value => 0  }, ]
}

1;