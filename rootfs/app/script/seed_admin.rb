# seed_admin.rb — first-boot admin seeder, invoked via `rails runner`.
#
# Skips silently when CONTAINER_DISCOURSE_ADMIN_EMAIL is unset (no-op for
# operators who do their first admin via the web onboarding flow). Skips
# silently when a real admin user already exists, so re-running this on every
# boot is safe and unsetting the env after first boot doesn't fight the
# operator. CONTAINER_DISCOURSE_ADMIN_PASSWORD is required only when an
# email is provided AND no admin yet exists.
#
# The `id > 0` filter excludes Discourse's built-in system users (system at
# id=-1, discobot at id=-2), which carry admin=true by default and would
# otherwise cause this script to short-circuit on every fresh DB.

email = ENV.fetch('CONTAINER_DISCOURSE_ADMIN_EMAIL') { exit 0 }
exit 0 if User.where(admin: true).where('id > 0').exists?

password = ENV.fetch('CONTAINER_DISCOURSE_ADMIN_PASSWORD')
username = ENV.fetch('CONTAINER_DISCOURSE_ADMIN_USERNAME', 'admin')

user = User.new(email: email, username: username, password: password, name: username)
user.admin = true
user.approved = true
user.active = true
user.save!
# Order matters: User#activate (user.rb:1440 in v2026.4.1) calls
# email_tokens.create! which fails on an unsaved parent. Save first, then
# activate — which creates and confirms a signup-scope EmailToken, so the
# operator can log in without going through web-side email verification.
user.activate
user.grant_admin!
puts "seeded admin user: #{username} <#{email}>"
