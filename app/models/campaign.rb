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
# Schema version: 23
#
# Table name: campaigns
#
#  id                  :integer(4)      not null, primary key
#  user_id             :integer(4)
#  assigned_to         :integer(4)
#  name                :string(64)      default(""), not null
#  access              :string(8)       default("Private")
#  status              :string(64)
#  budget              :decimal(12, 2)
#  target_leads        :integer(4)
#  target_conversion   :float
#  target_revenue      :decimal(12, 2)
#  leads_count         :integer(4)
#  opportunities_count :integer(4)
#  revenue             :decimal(12, 2)
#  starts_on           :date
#  ends_on             :date
#  objectives          :text
#  deleted_at          :datetime
#  created_at          :datetime
#  updated_at          :datetime
#  background_info  :string(255)
#
class Campaign < ActiveRecord::Base
  belongs_to  :user
  belongs_to  :assignee, :class_name => "User", :foreign_key => :assigned_to
  has_many    :tasks, :as => :asset, :dependent => :destroy, :order => 'created_at DESC'
  has_many    :leads, :dependent => :destroy, :order => "id DESC"
  has_many    :opportunities, :dependent => :destroy, :order => "id DESC"
  has_many    :activities, :as => :subject, :order => 'created_at DESC'

  named_scope :only, lambda { |filters| { :conditions => [ "status IN (?)" + (filters.delete("other") ? " OR status IS NULL" : ""), filters ] } }
  named_scope :created_by, lambda { |user| { :conditions => [ "user_id = ?" , user.id ] } }
  named_scope :assigned_to, lambda { |user| { :conditions => [ "assigned_to = ?", user.id ] } }

  # Prepare columns for filters based on settings
  filter_columns = { :name => { },
                     :user_id => { :text => "created_by", :source => lambda { |options| User.all.map { |user| [user.full_name, user.id] } } },
                     :assigned_to => { :source => lambda { |options| User.all.map { |user| [user.full_name, user.id] } } },
                     :created_at => {},
                     :updated_at => {},
                     :leads_count => {},
                     :revenue => {},
                     :starts_on => {},
                     :ends_on => {},
                     :objectives => {},
                     :status => { :source => lambda { |options| Setting.unroll(:campaign_status).map { |name, id| [name, id.to_s] } } }
                   }
  # Add background_info if enabled
  filter_columns.merge!(:background_info => {}) if Setting.background_info && Setting.background_info.include?(:campaign)

  acts_as_criteria :i18n                   => lambda { |text| I18n.t(text) },
                   :mantain_current_query  => lambda { |query, controller_name, session| session["#{controller_name}_current_query".to_sym] = query },
                   :restrict => { :method  => "my", :options => lambda { |current_user| { :user => current_user, :order => current_user.pref[:campaigns_sort_by] || Campaign.sort_by } } },
                   :paginate => { :method  => "paginate", :options => lambda { |current_user| { :page => 1, :per_page => current_user.pref[:campaigns_per_page]} } },
                   :simple   => { :columns => [:name], :match => :contains, :escape => lambda { |query| query.gsub(/[^\w\s\-\.']/, "").strip } },
                   :filter   => { :columns => filter_columns }

  uses_user_permissions
  acts_as_commentable
  acts_as_paranoid
  sortable :by => [ "name ASC", "target_leads DESC", "target_revenue DESC", "leads_count DESC", "revenue DESC", "starts_on DESC", "ends_on DESC", "created_at DESC", "updated_at DESC" ], :default => "created_at DESC"

  validates_presence_of :name, :message => :missing_campaign_name
  validates_uniqueness_of :name, :scope => :user_id
  validate :start_and_end_dates
  validate :users_for_shared_access

  # Default values provided through class methods.
  #----------------------------------------------------------------------------
  def self.per_page ; 20     ; end
  def self.outline  ; "long" ; end

  private
  # Make sure end date > start date.
  #----------------------------------------------------------------------------
  def start_and_end_dates
    if (self.starts_on && self.ends_on) && (self.starts_on > self.ends_on)
      errors.add(:ends_on, :dates_not_in_sequence)
    end
  end

  # Make sure at least one user has been selected if the campaign is being shared.
  #----------------------------------------------------------------------------
  def users_for_shared_access
    errors.add(:access, :share_campaign) if self[:access] == "Shared" && !self.permissions.any?
  end

end
