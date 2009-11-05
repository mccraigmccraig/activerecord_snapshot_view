require 'active_record'

# implements a write-once-read-many table, wherein there is a
# currently active version of a table, one or more historical
# versions and a working version. modifications are made
# by writing new data to the working version of the table
# and then switching the active version to what was the working version.
#
# each version is a separate database table, and there is a 
# switch table with a single row which names the currently live
# version table in the database

module ActiveRecord
  module WormTable
    def self.included(mod)
      mod.instance_eval do
        class << self
          include ClassMethods
        end
      end
    end

    module ClassMethods
      ALPHABET = "abcdefghijklmnopqrstuvwxyz"

      def ClassMethods.included(mod)
        mod.instance_eval do
          alias_method :org_table_name, :table_name
          alias_method :table_name, :active_table_name
        end
      end
      
      # hide the ActiveRecord::Base method, which redefines a table_name method,
      # and instead capture the given name as the base_table_name
      def set_table_name(name)
        @base_table_name = name
      end
      alias :table_name= :set_table_name

      def base_table_name
        if !@base_table_name
          @base_table_name = org_table_name
          class << self
            alias_method :table_name, :active_table_name
          end
        end
        @base_table_name
      end

      # number of historical tables to keep around for posterity, or more likely
      # to ensure running transactions aren't taken down by advance_version
      # recreating a table
      def historical_version_count
        @historical_version_count || 2
      end

      def set_historical_version_count(count)
        @historical_version_count = count
      end
      alias :historical_version_count= :set_historical_version_count

      # use schema of from table to recreate to table
      def dup_table_schema(from, to)
        connection.execute( "drop table if exists #{to}")
        ct = connection.select_one( "show create table #{from}")["Create Table"]
        ct_no_constraint_names = ct.gsub(/CONSTRAINT `[^`]*`/, "CONSTRAINT ``")
        i = 0
        ct_uniq_constraint_names = ct_no_constraint_names.gsub(/CONSTRAINT ``/) { |s| i+=1 ; "CONSTRAINT `#{to}_#{i}`" }

        new_ct = ct_uniq_constraint_names.gsub( /CREATE TABLE `#{from}`/, "CREATE TABLE `#{to}`")
        connection.execute(new_ct)
      end

      def ensure_version_table(name)
        if !connection.table_exists?(name) # don't execute ddl unless necessary
          dup_table_schema(base_table_name, name)
        end
      end

      # create a switch table of given name, if it doesn't already exist
      def create_switch_table(name)
        connection.execute( "create table if not exists #{name} (`current` varchar(255))" )
      end

      # create the switch table if it doesn't already exist. return the switch table name
      def ensure_switch_table
        stn = switch_table_name
        if !connection.table_exists?(stn) # don't execute any ddl code if we don't need to
          create_switch_table(stn)
        end
        stn
      end

      # name of the table with a row holding the active table name
      def switch_table_name
        base_table_name + "_switch"
      end
      
      # list of suffixed table names
      def suffixed_table_names
        suffixes = []
        (0...historical_version_count).each{ |i| suffixes << ALPHABET[i...i+1] }
        suffixes.map do |suffix|
          base_table_name + "_" + suffix
        end
      end
      
      # ordered vector of table version names, starting with base name
      def table_version_names
        [base_table_name] + suffixed_table_names
      end

      def default_active_table_name
        if !defined?(RAILS_ENV) || (RAILS_ENV !~ /^test/)
          base_table_name
        else
          # if in a test environment, make the default version table
          # one of the suffixed tables : code which doesn't use Model.table_name
          # will fail
          suffixed_table_names.first
        end
      end

      # name of the active table
      def active_table_name
        st = switch_table_name
        begin
          connection.select_value( "select current from #{st}" )
        rescue
        end || default_active_table_name
      end

      # name of the working table
      def working_table_name
        atn = active_table_name
        tvn = table_version_names
        tvn[ (tvn.index(atn) + 1) % tvn.size ]
      end

      def ensure_all_tables
        suffixed_table_names.each do |table_name|
          ensure_version_table(table_name)
        end
        ensure_switch_table
      end

      # make working table active, then recreate new working table from base table schema
      def advance_version
        st = ensure_switch_table

        # want a transaction at least here [surround is ok too] so 
        # there is never an empty switch table
        ActiveRecord::Base.transaction do
          wtn = working_table_name
          connection.execute( "delete from #{st}")
          connection.execute( "insert into #{st} values (\'#{wtn}\')")
        end

        # ensure the presence of the new active and working tables. 
        # happens after the switch table update, since this may commit a surrounding 
        # transaction in dbs with retarded non-transactional ddl like, oh i dunno, MyFuckingSQL
        ensure_version_table(active_table_name)

        # recreate the new working table from the base schema. 
        new_wtn = working_table_name
        if new_wtn != base_table_name
          dup_table_schema(base_table_name, new_wtn)
        else
          connection.execute( "truncate table #{new_wtn}" )
        end

      end
    end
  end
end
