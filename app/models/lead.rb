# Fat Free CRM
# Copyright (C) 2008-2010 by Michael Dvorkin
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#------------------------------------------------------------------------------

# == Schema Information
# Schema version: 26
#
# Table name: leads
#
#  id          :integer(4)      not null, primary key
#  user_id     :integer(4)
#  campaign_id :integer(4)
#  assigned_to :integer(4)
#  first_name  :string(64)      default(""), not null
#  last_name   :string(64)      default(""), not null
#  access      :string(8)       default("Private")
#  title       :string(64)
#  company     :string(64)
#  source      :string(32)
#  status      :string(32)
#  referred_by :string(64)
#  email       :string(64)
#  alt_email   :string(64)
#  phone       :string(32)
#  mobile      :string(32)
#  blog        :string(128)
#  linkedin    :string(128)
#  facebook    :string(128)
#  twitter     :string(128)
#  rating      :integer(4)      default(0), not null
#  do_not_call :boolean(1)      not null
#  deleted_at  :datetime
#  created_at  :datetime
#  updated_at  :datetime
#  background_info  :string(255)
#
class Lead < ActiveRecord::Base
  belongs_to  :user
  belongs_to  :campaign
  belongs_to  :assignee, :class_name => "User", :foreign_key => :assigned_to
  has_one     :contact, :dependent => :nullify # On destroy keep the contact, but nullify its lead_id
  has_many    :tasks, :as => :asset, :dependent => :destroy, :order => 'created_at DESC'
  has_many    :activities, :as => :subject, :order => 'created_at DESC'
  has_one     :business_address, :dependent => :destroy, :as => :addressable, :class_name => "Address", :conditions => "address_type='Business'"

  accepts_nested_attributes_for :business_address, :allow_destroy => true
  
  named_scope :only, lambda { |filters| { :conditions => [ "status IN (?)" + (filters.delete("other") ? " OR status IS NULL" : ""), filters ] } }
  named_scope :converted, :conditions => "status='converted'"
  named_scope :for_campaign, lambda { |id| { :conditions => [ "campaign_id=?", id ] } }
  named_scope :created_by, lambda { |user| { :conditions => [ "user_id = ?" , user.id ] } }
  named_scope :assigned_to, lambda { |user| { :conditions => ["assigned_to = ? " , user.id ] } }
  
  # Prepare columns for filters based on settings
  filter_columns = { :first_name => { },
                     :last_name => { },
                     :user_id => { :text => "created_by", :source => lambda { |options| User.all.map { |user| [user.full_name, user.id] } } },
                     :assigned_to => { :source => lambda { |options| User.all.map { |user| [user.full_name, user.id] } } },
                     :created_at => {},
                     :updated_at => {},
                     :email => {},
                     :status => { :source => lambda { |options| Setting.unroll(:lead_status).map { |name, id| [name, id.to_s] } } },
                     :source => { :source => lambda { |options| Setting.unroll(:lead_source).map { |name, id| [name, id.to_s] } } }
                   }
  # Add background_info if enabled
  filter_columns.merge!(:background_info => {}) if Setting.background_info && Setting.background_info.include?(:lead)
  # Include splitted addresses if enabled
  if Setting.compound_address
    filter_address = { :"addresses.country" => { :text => "country", :relation_name => :business_address, :source => lambda { |options| Country.all } },
                       :"addresses.city" => { :text => "city", :relation_name => :business_address },
                       :"addresses.zipcode" => { :text => "zipcode", :relation_name => :business_address },
                       :"addresses.state" => { :text => "state", :relation_name => :business_address }
                     }
  else
    filter_address = { :"addresses.full_address" => { :text => "full_address", :relation_name => :business_address } }
  end
  filter_columns.merge!(filter_address)
  acts_as_criteria :i18n                   => lambda { |text| I18n.t(text) },
                   :mantain_current_query  => lambda { |query, controller_name, session| session["#{controller_name}_current_query".to_sym] = query },
                   :restrict => { :method  => "my", :options => lambda { |current_user| { :user => current_user, :order => current_user.pref[:leads_sort_by] || Lead.sort_by } } },
                   :paginate => { :method  => "paginate", :options => lambda { |current_user| { :page => 1, :per_page => current_user.pref[:leads_per_page]} } },
                   :simple   => { :columns => [:first_name, :last_name, :company], :match => :contains, :escape => lambda { |query| query.gsub(/[^\w\s\-\.']/, "").strip } },
                   :filter   => { :columns => filter_columns }
                 
  uses_user_permissions
  acts_as_commentable
  acts_as_paranoid
  sortable :by => [ "first_name ASC", "last_name ASC", "company ASC", "rating DESC", "created_at DESC", "updated_at DESC" ], :default => "created_at DESC"

  validates_presence_of :first_name, :message => :missing_first_name
  validates_presence_of :last_name, :message => :missing_last_name
  validate :users_for_shared_access

  after_create  :increment_leads_count
  after_destroy :decrement_leads_count

  # Default values provided through class methods.
  #----------------------------------------------------------------------------
  def self.per_page ; 20                  ; end
  def self.outline  ; "long"              ; end
  def self.first_name_position ; "before" ; end

  # Save the lead along with its permissions.
  #----------------------------------------------------------------------------
  def save_with_permissions(params)
    self.campaign = Campaign.find(params[:campaign]) unless params[:campaign].blank?
    if self.access == "Campaign" && self.campaign # Copy campaign permissions.
      save_with_model_permissions(Campaign.find(self.campaign_id))
    else
      super(params[:users]) # invoke :save_with_permissions in plugin.
    end
  end

  # Update lead attributes taking care of campaign lead counters when necessary.
  #----------------------------------------------------------------------------
  def update_with_permissions(attributes, users)
    if self.campaign_id == attributes[:campaign_id] # Same campaign (if any).
      super(attributes, users)                      # See lib/fat_free_crm/permissions.rb
    else                                            # Campaign has been changed -- update lead counters...
      decrement_leads_count                         # ..for the old campaign...
      lead = super(attributes, users)               # Assign new campaign.
      increment_leads_count                         # ...and now for the new campaign.
      lead
    end
  end

  # Promote the lead by creating contact and optional opportunity. Upon
  # successful promotion Lead status gets set to :converted.
  #----------------------------------------------------------------------------
  def promote(params)
    account     = Account.create_or_select_for(self, params[:account], params[:users])
    opportunity = Opportunity.create_for(self, account, params[:opportunity], params[:users])
    contact     = Contact.create_for(self, account, opportunity, params)

    return account, opportunity, contact
  end

  #----------------------------------------------------------------------------
  def convert
    update_attribute(:status, "converted")
  end

  #----------------------------------------------------------------------------
  def reject
    update_attribute(:status, "rejected")
  end

  #----------------------------------------------------------------------------
  def full_name(format = nil)
    if format.nil? || format == "before"
      "#{self.first_name} #{self.last_name}"
    else
      "#{self.last_name}, #{self.first_name}"
    end
  end
  alias :name :full_name

  private
  #----------------------------------------------------------------------------
  def increment_leads_count
    if self.campaign_id
      Campaign.increment_counter(:leads_count, self.campaign_id)
    end
  end

  #----------------------------------------------------------------------------
  def decrement_leads_count
    if self.campaign_id
      Campaign.decrement_counter(:leads_count, self.campaign_id)
    end
  end

  # Make sure at least one user has been selected if the lead is being shared.
  #----------------------------------------------------------------------------
  def users_for_shared_access
    errors.add(:access, :share_lead) if self[:access] == "Shared" && !self.permissions.any?
  end

end
