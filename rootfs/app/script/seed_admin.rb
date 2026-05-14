# seed_admin.rb — first-boot admin seeder, invoked via `rails runner`.
#
# Skips silently when CONTAINER_DISCOURSE_ADMIN_EMAIL is unset (no-op for
# operators who do their first admin via the web onboarding flow). Skips
# silently when any admin user already exists, so re-running this on every
# boot is safe and unsetting the env after first boot doesn't fight the
# operator. CONTAINER_DISCOURSE_ADMIN_PASSWORD is required only when an
# email is provided AND no admin yet exists.

email = ENV.fetch('CONTAINER_DISCOURSE_ADMIN_EMAIL') { exit 0 }
exit 0 if User.where(admin: true).exists?

password = ENV.fetch('CONTAINER_DISCOURSE_ADMIN_PASSWORD')
username = ENV.fetch('CONTAINER_DISCOURSE_ADMIN_USERNAME', 'admin')

user = User.new(email: email, username: username, password: password, name: username)
user.admin = true
user.approved = true
user.activate
user.save!
user.email_tokens.create!(email: email).confirm
user.grant_admin!
puts "seeded admin user: #{username} <#{email}>"
