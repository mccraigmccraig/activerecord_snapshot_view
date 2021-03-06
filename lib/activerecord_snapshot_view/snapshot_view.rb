# implements snapshot materialized views for ActiveRecord
# 
# currently active version of a view, one or more historical
# versions and a working version. modifications are made
# by writing new data to the working version of the table
# and then switching the active version to what was the working version.
#
# each version is a separate database table, and there is a 
# switch table with a single row which names the currently live
# version table in the database

# AssocationReflection caches table names... we have to undo this
module ActiveRecord
  module Reflection
    class AssociationReflection
      def table_name
        klass.table_name
      end

      def quoted_table_name
        klass.quoted_table_name
      end
    end
  end
end

module ActiveRecord
  module SnapshotView
    def self.included(mod)
      mod.instance_eval do
        class << self
          include ClassMethods
        end
      end
    end

    def self.class_from_symbol(sym)
      eval(sym.to_s.camelize)
    end

    # prepare a SnapshotView model for migration... move all data to the 
    # base table, make that current, and remove the other store tables.
    # if the model no longer exists, or is no longer a SnapshotView,
    # catch any errors
    def self.prepare_to_migrate(model_sym)
      begin
        klass = class_from_symbol(model_sym)
        if klass.ancestors.include?(ActiveRecord::SnapshotView)
          klass.prepare_to_migrate
        end
      rescue Exception=>e
        $stderr << "model: #{model_sym} no longer exists?\nignored Exception:\n"
        $stderr << [e.message, *e.backtrace].join("\n")
      end
    end

    # remove all SnapshotView related tables for a model, making it a normal model again
    # does not require that the SnapshotView module is included on the model class
    def self.normalize(base_table)
      view_tables = ActiveRecord::Base::connection.tables.select{|n| n=~ /^#{base_table}_([[:alpha:]]|switch)$/}

      $stderr << "#{base_table} matches no view_tables\n" if view_tables.empty?
      view_tables.each do |table|
        ActiveRecord::Base::connection.execute( "drop table #{table}" )
      end

    end

    # if a block given to the +new_version+ method throws this exception,
    # then the working table will still be made current
    class SaveWork < Exception
      attr_reader :cause
      def initialize(cause=nil)
        @cause = cause
      end

      def message
        (@cause.message if @cause) || "SaveWork"
      end

      def backtrace
        (@cause.backtrace if @cause) || super
      end
    end

    module ClassMethods
      ALPHABET = "abcdefghijklmnopqrstuvwxyz"

      def ClassMethods.included(mod)
        mod.instance_eval do
          alias_method :org_table_name, :table_name
          alias_method :table_name, :active_working_table_or_active_table_name
        end
      end
      
      # number of historical tables to keep around for posterity, or more likely
      # to ensure running transactions aren't taken down by advance_version
      # recreating a table. default 2
      def historical_version_count
        @historical_version_count || 2
      end

      # set the number of historical tables to keep around to ensure running 
      # transactions aren't interrupted by truncating working tables. 2 is default
      def set_historical_version_count(count)
        @historical_version_count = count
      end
      alias :historical_version_count= :set_historical_version_count

      # hide the ActiveRecord::Base method, which redefines a table_name method,
      # and instead capture the given name as the base_table_name
      def set_table_name(name)
        @base_table_name = name
      end
      alias :table_name= :set_table_name

      def base_table_name
        if !@base_table_name
          @base_table_name = org_table_name
          # the original table_name method re-aliases itself !
          class << self
            alias_method :table_name, :active_working_table_or_active_table_name
          end
        end
        @base_table_name
      end

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

      # copy all data to base table, reset switch table and drop suffixed tables... for migration support
      def prepare_to_migrate
        if active_table_name != base_table_name
          connection.execute( "truncate table #{base_table_name}" )
          connection.execute( "insert into #{base_table_name} select * from #{active_table_name}" )
        end
        suffixed_table_names.each do |stn|
          connection.execute( "drop table if exists #{stn}" )
        end
        connection.execute( "drop table if exists #{switch_table_name}" )
      end

      def ensure_version_table(name)
        if !connection.table_exists?(name) &&
            base_table_name!=name # don't execute ddl unless necessary
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
        # no longer use a different table name for test environments...
        # it makes a mess with named scopes
        base_table_name
      end

      # name of the active table read direct from db
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
      
      # update switch table to point to a different table
      def switch_to(table)
        st = ensure_switch_table
        # want a transaction at least here [surround is ok too] so 
        # there is never an empty switch table
        ActiveRecord::Base.transaction do
          connection.execute( "delete from #{st}")
          connection.execute( "insert into #{st} values (\'#{table}\')")
        end
      end

      # make working table active, then recreate new working table from base table schema
      def advance_version
        switch_to(working_table_name)

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

      def thread_local_key_name
        "ActiveRecord::SnapshotView::" + self.to_s
      end

      def active_working_table_name
        Thread.current[thread_local_key_name]
      end

      def active_working_table_name=(name)
        Thread.current[thread_local_key_name] = name
      end

      # name of the active table, or the working table if inside a new_version block
      def active_working_table_or_active_table_name
        active_working_table_name || active_table_name
      end

      # like new_version, but instead of an empty table you start with
      # a copy of the previous version (if update=true)
      def updated_version(update=true, &block)
        new_version do
          if update
            sql = <<-EOF
              insert into #{working_table_name}
              select * from #{active_table_name}
            EOF
            connection.execute(sql)
          end
          block.call
        end
      end

      # make the working table temporarily active [ for this thread only ], 
      # execute the block, and if completed without exception then
      # make the working table permanently active
      def new_version(&block)
        begin
          self.active_working_table_name = working_table_name
          ensure_version_table(working_table_name)
          connection.execute("truncate table #{working_table_name}")
          r = block.call
          advance_version
          r
        rescue SaveWork => e
          advance_version
          raise e # raise the SaveWork again, in case we are inside nested new_versions
        ensure
          self.active_working_table_name = nil
        end
      end
    end
  end
end
