require 'vend/enumerating/concatenator'

module Vend::Sync
  class Import
    attr_accessor :client, :imports

    delegate :connection, to: 'ActiveRecord::Base'

    # specify date fields to explicitly include/exclude
    # *_at and *_date fields are automatically included
    IGNORED_DATE_FIELDS  = %w(year_to_date)
    EXPLICIT_DATE_FIELDS = %w(valid_from valid_to date_of_birth)

    def initialize(address, token)
      Upsert.logger.level = Logger::WARN
      build_client(address, token)
    end

    def import(class_names = all_class_names)
      Array.wrap(class_names).each do |class_name|
        build_imports(class_name)
      end
    end

    private

    def build_client(address, token)
      @client = Vend::Oauth2::Client.new(address, token)
    end

    def all_class_names
      [
        :Outlet, :Product, :Customer, :PaymentType, :Register, :RegisterSale,
        :Tax, :User
      ]
    end

    def build_table_name(class_name)
      class_name.to_s.underscore.pluralize
    end

    def build_table(table_name, records)
      unless connection.table_exists?(table_name)
        connection.create_table table_name, id: false do |t|
          t.timestamps null: true
        end
      end
      build_columns(table_name, records)
    end

    def build_columns(table_name, records)
      columns = {}
      records.each do |attributes|
        attributes.each do |key, value|
          columns[key] ||= column_type(key, value)
        end
      end
      columns.each do |name, type|
        build_column(table_name, name, type)
      end
    end

    def build_column(table_name, name, type)
      unless connection.column_exists?(table_name, name)
        connection.add_column(table_name, name, type)
        if name == 'id'
          connection.add_index(table_name, name, unique: true)
        elsif name.ends_with?('_id')
          connection.add_index(table_name, name)
        end
      end
    end

    def column_type(key, value)
      if key == 'id' or key.ends_with?('_id')
        :string
      elsif is_date_time_field?(key)
        :datetime
      else
        case value
        when Integer
          :decimal
        when TrueClass, FalseClass
          :boolean
        else
          :text
        end
      end
    end

    def fetch_resources(class_name)
      klass = client.send(class_name)
      collections = [ klass.all ]

      # VOIDED register sales are not returned by default
      if klass.respond_to?(:find_by_state)
        collections << klass.find_by_state('VOIDED')
      end

      collections.each do |collection|
        if collection.accepts_scope?(:since) and
            since = last_updated_at(class_name)
          collection.since(since)
        end
      end
      Enumerating::Concatenator.new(collections)
    end

    def last_updated_at(class_name)
      table_name = build_table_name(class_name)
      if connection.table_exists?(table_name) and
          connection.column_exists?(table_name, :updated_at)
        connection.select_value("select max(updated_at) from #{table_name}")
      end
    end

    def build_imports(class_name)
      print class_name.to_s.pluralize
      self.imports = {}
      table_name = build_table_name(class_name)
      fetch_resources(class_name).each do |resource|
        print '.'
        build_import(table_name, resource.attrs)
      end
      imports.each do |table_name, records|
        build_table(table_name, records)
        Upsert.batch(connection, table_name, {assume_function_exists: false}) do |upsert|
          records.each do |attributes|
            upsert.row(attributes.slice('id'), attributes.slice!('id'))
          end
        end
      end
      puts
    end

    def build_import(table_name, attrs)
      if id = attrs['id']
        attributes = {}
        attrs.each do |key, value|
          # append _ to prevent conflict with upsert
          key = key + '_' if key.ends_with?('_sel') or key.ends_with?('_set')
          case value
          when Array
            value.each do |v|
              if v.class == Hash
                build_import(key, v.merge(foreign_key(table_name, id)))
              else
                puts "Ignoring #{key} => #{v} on #{table_name}"
              end
            end
          when Hash
            build_import(key.pluralize, value)
            attributes[key + '_id'] = value['id']
          else
            attributes[key] = value if value.present?
          end
          attributes[key] = DateTime.parse(value) if value.present? and is_date_time_field?(key)
        end
        attributes['updated_at'] = DateTime.now unless attrs['updated_at']
        imports[table_name] ||= []
        imports[table_name] << attributes
      else
        # puts "skipping composite key #{table_name}: #{attrs.keys.join(', ')}"
      end
    end

    def foreign_key(table_name, id)
      {table_name.singularize + '_id' => id}
    end

    def is_date_time_field?(key)
      !IGNORED_DATE_FIELDS.include?(key) &&
        (key.ends_with?('_date') or key.ends_with?('_at') or EXPLICIT_DATE_FIELDS.include?(key))
    end

  end
end
