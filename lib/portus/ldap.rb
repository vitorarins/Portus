require "net/ldap"
require "devise/strategies/authenticatable"

module Portus
  # Portus::LDAP implements Devise's authenticatable for LDAP servers. This
  # class will fallback to other strategies if LDAP support is not enabled.
  #
  # If we can bind to the server with the given credentials, we assume that
  # the authentication was successful. In this case, if this is the first time
  # that this user enters Portus, it will be saved inside of Portus' DB. There
  # are some issues while doing this:
  #
  #   1. The 'email' is not provided in a standard way: some LDAP servers may
  #      provide it, some others won't. Therefore, once an LDAP user logs in
  #      Portus for the first time, the email will be left blank. This should
  #      be handled by the controller layer.
  #   2. The 'password' is stored in the DB but it's not really used. This is
  #      because the DB requires the password to not be blank, but in order to
  #      authenticate we always want to check with the LDAP server.
  #
  # This class is only useful if LDAP is enabled in the `config/config.yml`
  # file. Take a look at this file in order to read more on the different
  # configurable values.
  class LDAP < Devise::Strategies::Authenticatable
    # Re-implemented from Devise::Strategies::Authenticatable to authenticate
    # the user.
    def authenticate!
      ldap = load_configuration

      # If LDAP is enabled try to authenticate through the LDAP server.
      # Otherwise we fall back to the next strategy.
      if ldap
        # Try to bind to the LDAP server. If there's any failure, the
        # authentication process will fail without going to the any other
        # strategy.
        if ldap.bind_as(bind_options)
          user = find_or_create_user!
          user.valid? ? success!(user) : fail!(:invalid_login)
        else
          fail!(:invalid_login)
        end
      else
        # rubocop:disable Style/SignalException
        fail(:invalid_login)
        # rubocop:enable Style/SignalException
      end
    end

    # Returns true if LDAP has been enabled in the application, false
    # otherwise.
    def self.enabled?
      APP_CONFIG.enabled?("ldap")
    end

    protected

    # Loads the configuration and authenticates the current user.
    def load_configuration
      return nil if !::Portus::LDAP.enabled? || params[:user].nil?

      cfg = APP_CONFIG["ldap"]
      adapter.new(host: cfg["hostname"], port: cfg["port"])
    end

    # Returns the class to be used for LDAP support. Mainly declared this way
    # so tests can mock this away. This can also be useful if we decide to jump
    # on another gem for LDAP support.
    def adapter
      Net::LDAP
    end

    # Returns the option hash to be used in order to authenticate the user in
    # the LDAP server.
    def bind_options
      {}.tap do |opts|
        opts[:filter]   = "(uid=#{username})"
        opts[:password] = password
        opts[:base]     = APP_CONFIG["ldap"]["base"] unless APP_CONFIG["ldap"]["base"].empty?
      end
    end

    # Retrieve the given user as an LDAP user. If it doesn't exist, create it
    # with the parameters given in the form.
    def find_or_create_user!
      user = User.find_by(ldap_name: username)

      # The user does not exist in Portus yet, let's create it. If it does
      # not match a valid username, it will be transformed into a proper one.
      unless user
        ldap_name = username.dup
        if User::USERNAME_FORMAT.match(ldap_name)
          name = ldap_name
        else
          name = ldap_name.gsub(/[^#{User::USERNAME_CHARS}]/, "")
        end

        # This is to check that no clashes occur. This is quite improbable to
        # happen, since it would mean that the name contains characters like
        # "$", "!", etc. We also check that the name is longer than 4
        # (requirement from Docker).
        if name.length < 4 || User.exists?(username: name)
          name = generate_random_name(name)
        end

        user = User.create(
          username:  name,
          password:  password,
          admin:     !User.not_portus.any?,
          ldap_name: ldap_name
        )
      end
      user
    end

    # It generates a new name that doesn't clash with any of the existing ones.
    def generate_random_name(name)
      # Even if the name has just one character, adding a number of at least
      # three digits would make the name valid.
      offset = name.length < 4 ? 100 : 0

      10.times do
        nn = "#{name}#{Random.rand(offset + 101)}"
        return nn unless User.exists?(username: nn)
      end

      # We have not been able to generate a new name, let's raise an exception.
      fail!(:invalid_login)
    end

    ##
    # Parameters.

    def username
      params[:user][:username]
    end

    def password
      params[:user][:password]
    end
  end
end
