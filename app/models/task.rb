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
# Schema version: 27
#
# Table name: tasks
#
#  id              :integer(4)      not null, primary key
#  user_id         :integer(4)
#  assigned_to     :integer(4)
#  completed_by    :integer(4)
#  name            :string(255)     default(""), not null
#  asset_id        :integer(4)
#  asset_type      :string(255)
#  priority        :string(32)
#  category        :string(32)
#  bucket          :string(32)
#  due_at          :datetime
#  completed_at    :datetime
#  deleted_at      :datetime
#  created_at      :datetime
#  updated_at      :datetime
#  background_info :string(255)
#
class Task < ActiveRecord::Base
  attr_accessor :calendar

  belongs_to  :user
  belongs_to  :assignee, :class_name => "User", :foreign_key => :assigned_to
  belongs_to  :completor, :class_name => "User", :foreign_key => :completed_by
  belongs_to  :asset, :polymorphic => true
  has_many    :activities, :as => :subject, :order => 'created_at DESC'

  # Tasks created by the user for herself, or assigned to her by others. That's
  # what gets shown on Tasks/Pending and Tasks/Completed pages.
  named_scope :my, lambda { |user| {
    :conditions => [ "(user_id = ? AND assigned_to IS NULL) OR assigned_to = ?", user[:user] || user, user[:user] || user ],
    :order => user[:order] || "name ASC",
    :limit => user[:limit], # nil selects all records
    :include => :assignee
  } }
  
  named_scope :assigned_to, lambda { |user| {
    :conditions => ["completed_at IS NULL AND assigned_to = ?", user[:user] || user],
    :order => user[:order] || "due_at ASC",
    :limit => user[:limit], # nil selects all records
    :include => :assignee
  } }

  # Tasks assigned by the user to others. That's what we see on Tasks/Assigned.
  named_scope :assigned_by, lambda { |user| { :conditions => [ "user_id = ? AND assigned_to IS NOT NULL AND assigned_to != ?", user.id, user.id ], :include => :assignee } }

  # Tasks created by the user or assigned to the user, i.e. the union of the two
  # scopes above. That's the tasks the user is allowed to see and track.
  named_scope :tracked_by, lambda { |user| { :conditions => [ "user_id = ? OR assigned_to = ?", user.id, user.id ], :include => :assignee } }

  # Status based scopes to be combined with the due date and completion time.
  named_scope :pending,       :conditions => "completed_at IS NULL", :order => "due_at, id"
  named_scope :assigned,      :conditions => "completed_at IS NULL AND assigned_to IS NOT NULL", :order => "due_at, id"
  named_scope :completed,     :conditions => "completed_at IS NOT NULL", :order => "completed_at DESC"

  # Due date scopes.
  named_scope :due_asap,      :conditions => "due_at IS NULL AND bucket = 'due_asap'", :order => "id DESC"
  named_scope :overdue,       lambda { { :conditions => [ "due_at IS NOT NULL AND due_at < ?", Time.zone.now.midnight.utc ], :order => "id DESC" } }
  named_scope :due_today,     lambda { { :conditions => [ "due_at >= ? AND due_at < ?", Time.zone.now.midnight.utc, Time.zone.now.midnight.tomorrow.utc ], :order => "id DESC" } }
  named_scope :due_tomorrow,  lambda { { :conditions => [ "due_at >= ? AND due_at < ?", Time.zone.now.midnight.tomorrow.utc, Time.zone.now.midnight.tomorrow.utc + 1.day ], :order => "id DESC" } }
  named_scope :due_this_week, lambda { { :conditions => [ "due_at >= ? AND due_at < ?", Time.zone.now.midnight.tomorrow.utc + 1.day, Time.zone.now.next_week.utc ], :order => "id DESC" } }
  named_scope :due_next_week, lambda { { :conditions => [ "due_at >= ? AND due_at < ?", Time.zone.now.next_week.utc, Time.zone.now.next_week.end_of_week.utc + 1.day ], :order => "id DESC" } }
  named_scope :due_later,     lambda { { :conditions => [ "(due_at IS NULL AND bucket = 'due_later') OR due_at >= ?", Time.zone.now.next_week.end_of_week.utc + 1.day ], :order => "id DESC" } }

  # Completion time scopes.
  named_scope :completed_today,      lambda { { :conditions => [ "completed_at >= ? AND completed_at < ?", Time.zone.now.midnight.utc, Time.zone.now.midnight.tomorrow.utc ] } }
  named_scope :completed_yesterday,  lambda { { :conditions => [ "completed_at >= ? AND completed_at < ?", Time.zone.now.midnight.yesterday.utc, Time.zone.now.midnight.utc ] } }
  named_scope :completed_this_week,  lambda { { :conditions => [ "completed_at >= ? AND completed_at < ?", Time.zone.now.beginning_of_week.utc , Time.zone.now.midnight.yesterday.utc ] } }
  named_scope :completed_last_week,  lambda { { :conditions => [ "completed_at >= ? AND completed_at < ?", Time.zone.now.beginning_of_week.utc - 7.days, Time.zone.now.beginning_of_week.utc ] } }
  named_scope :completed_this_month, lambda { { :conditions => [ "completed_at >= ? AND completed_at < ?", Time.zone.now.beginning_of_month.utc, Time.zone.now.beginning_of_week.utc - 7.days ] } }
  named_scope :completed_last_month, lambda { { :conditions => [ "completed_at >= ? AND completed_at < ?", (Time.zone.now.beginning_of_month.utc - 1.day).beginning_of_month.utc, Time.zone.now.beginning_of_month.utc ] } }

  simple_column_search :name, :match => :middle, :escape => lambda { |query| query.gsub(/[^\w\s\-\.']/, "").strip }
  acts_as_commentable
  acts_as_paranoid

  validates_presence_of :user
  validates_presence_of :name, :message => :missing_task_name
  validates_presence_of :calendar, :if => "self.bucket == 'specific_time' && !self.completed_at"
  validate              :specific_time, :unless => :completed?

  before_create :set_due_date
  before_update :set_due_date, :unless => :completed?
  before_save :notify_assignee

  # Matcher for the :my named scope.
  #----------------------------------------------------------------------------
  def my?(user)
    (self.user == user && assignee.nil?) || assignee == user
  end

  # Matcher for the :assigned_by named scope.
  #----------------------------------------------------------------------------
  def assigned_by?(user)
    self.user == user && assignee && assignee != user
  end

  #----------------------------------------------------------------------------
  def completed?
    !!self.completed_at
  end

  # Matcher for the :tracked_by? named scope.
  #----------------------------------------------------------------------------
  def tracked_by?(user)
    self.user == user || self.assignee == user
  end

  # Check whether the due date has specific time ignoring 23:59:59 timestamp
  # set by Time.now.end_of_week.
  #----------------------------------------------------------------------------
  def at_specific_time?
    self.due_at &&
    (self.due_at.hour != 0 || self.due_at.min != 0 || self.due_at.sec != 0) &&
    (self.due_at.hour != 23 && self.due_at.min != 59 && self.due_at.sec != 59)
  end

  # Convert specific due_date to "due_today", "due_tomorrow", etc. bucket name.
  #----------------------------------------------------------------------------
  def computed_bucket
    return self.bucket if self.bucket != "specific_time"
    case
    when self.due_at < Time.zone.now.midnight
      "overdue"
    when self.due_at >= Time.zone.now.midnight && self.due_at < Time.zone.now.midnight.tomorrow
      "due_today"
    when self.due_at >= Time.zone.now.midnight.tomorrow && self.due_at < Time.zone.now.midnight.tomorrow + 1.day
      "due_tomorrow"
    when self.due_at >= (Time.zone.now.midnight.tomorrow + 1.day) && self.due_at < Time.zone.now.next_week
      "due_this_week"
    when self.due_at >= Time.zone.now.next_week && self.due_at < (Time.zone.now.next_week.end_of_week + 1.day)
      "due_next_week"
    else
      "due_later"
    end
  end

  # Returns list of tasks grouping them by due date as required by tasks/index.
  #----------------------------------------------------------------------------
  def self.find_all_grouped(user, view)
    settings = (view == "completed" ? Setting.task_completed : Setting.task_bucket)
    settings.inject({}) do |hash, key|
      hash[key] = (view == "assigned" ? assigned_by(user).send(key).pending : my(user).send(key).send(view))
      hash
    end
  end

  # Returns bucket if it's empty (i.e. we have to hide it), nil otherwise.
  #----------------------------------------------------------------------------
  def self.bucket_empty?(bucket, user, view = "pending")
    return false if bucket.blank?
    if view == "assigned"
      assigned_by(user).send(bucket).pending.count
    else
      my(user).send(bucket).send(view).count
    end == 0
  end

  # Returns task totals for each of the views as needed by tasks sidebar.
  #----------------------------------------------------------------------------
  def self.totals(user, view = "pending")
    settings = (view == "completed" ? Setting.task_completed : Setting.task_bucket)
    settings.inject({ :all => 0 }) do |hash, key|
      hash[key] = (view == "assigned" ? assigned_by(user).send(key).pending.count : my(user).send(key).send(view).count)
      hash[:all] += hash[key]
      hash
    end
  end

  private
  #----------------------------------------------------------------------------
  def set_due_date
    self.due_at = case self.bucket
    when "overdue"
      self.due_at || Time.zone.now.midnight.yesterday
    when "due_today"
      Time.zone.now.midnight
    when "due_tomorrow"
      Time.zone.now.midnight.tomorrow
    when "due_this_week"
      Time.zone.now.end_of_week
    when "due_next_week"
      Time.zone.now.next_week.end_of_week
    when "due_later"
      Time.zone.now.midnight + 100.years
    when "specific_time"
      self.calendar ? Time.parse(self.calendar).utc : nil
    else # due_later or due_asap
      nil
    end
  end

  #----------------------------------------------------------------------------
  def notify_assignee
    if self.assigned_to
      # Notify assignee.
    end
  end

  #----------------------------------------------------------------------------
  def specific_time
    Time.parse(self.calendar).utc if self.bucket == "specific_time"
  rescue
    errors.add(:calendar, :invalid_date)
  end
end
