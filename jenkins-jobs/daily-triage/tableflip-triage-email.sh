#!/bin/bash
#
# Note: this job relies on the system's ability to send mail via /usr/sbin/sendmail.
#
# To run this script without sending mail, set TRIAGE_NO_SENDMAIL non-empty in
# the environment.

set -eufx -o pipefail

export LC_ALL=C.UTF-8

TRIAGE_NO_SENDMAIL="${TRIAGE_NO_SENDMAIL-""}"


# Do we have the required tools?
command -v ubuntu-bug-triage
[ -z "$TRIAGE_NO_SENDMAIL" ] && command -v /usr/sbin/sendmail


# Projects to triage
projects=(cloud-init cloud-utils simplestreams ubuntu-advantage-tools)
github_projects=(cloud-init pycloudlib)
ndays_new_bugs=90

# GitHub usernames of team members, comma-separated for use in jq filters
team_members="blackboxsw,TheRealFalcon,lucasmoura,paride,orndorffgrant,renanrodrigo,CalvoM"


# Find today's triagers.
cloud_init_triagers=(James Chad Brett)
ua_triagers=(Grant Lucas Renan)
week=$(date --utc '+%-V')
dow=$(date --utc '+%u')

# Bash is the worst...
# The point here is to determine the current day of the year
# excluding weekends. E.g., if day 1 is a Monday, day 5 is Friday,
# the following Monday is day 6. We can then use this number to
# mod by the number of triages to cycle our triagers throughout the year.
# Sorry to anybody who might get double triage on January 1st ;)
triager_index=$((week * 5 + dow))
cloud_init_triager_count=${#cloud_init_triagers[@]}
ua_triager_count=${#ua_triagers[@]}
ndays=1
cloud_init_triager="nobody"
ua_triager="nobody"
if [[ "$dow" -ge 1 && "$dow" -le 5 ]]; then
    if [ $dow -eq 1 ]; then
        ndays=3
    fi
    cloud_init_triager=${cloud_init_triagers[$((triager_index % cloud_init_triager_count))]}
    ua_triager=${ua_triagers[$((triager_index % ua_triager_count))]}
fi

# Retrieve the bugs
for project in "${projects[@]}"; do
    : > "$project-bugs.text"

    echo "[Incomplete, Confirmed, Triaged and In Progress bugs]" > "$project-bugs.text.tmp"
    ubuntu-bug-triage --anon -s Incomplete -s Confirmed -s Triaged -s "In Progress" --include-project "$project" "$ndays" >> "$project-bugs.text.tmp"
    grep -q LP "$project-bugs.text.tmp" && cat "$project-bugs.text.tmp" > "$project-bugs.text"

    echo "[New bugs]" > "$project-bugs.text.tmp"
    ubuntu-bug-triage --anon -s New --include-project "$project" "$ndays_new_bugs" >> "$project-bugs.text.tmp"
    if grep -q LP "$project-bugs.text.tmp"; then
        [[ -s $project-bugs.text ]] && echo >> "$project-bugs.text"
        cat "$project-bugs.text.tmp" >> "$project-bugs.text"
    fi

    [[ ! -s $project-bugs.text ]] && echo None > "$project-bugs.text"
    rm -f "$project-bugs.text.tmp"
done


for project in "${github_projects[@]}"; do
    rm -f "$project-reviews.text" "$project-reviews.html"

    # Fetch all pull requests
    curl "https://api.github.com/repos/canonical/$project/pulls" > pulls.json

    # Reverse order so oldest are displayed first, convert to JSON Lines to
    # reduce repeated work in next step, filter out assigned PRs, filter out
    # PRs submitted by core committers
    jq -r "reverse | .[] | select(.assignee == null) | select(.user.login | inside(\"$team_members\") | not)" pulls.json > relevant_pulls.jsonl

    # Use jq's string interpolation to generate the text and HTML output
    jq -r '"* PR #\(.number): \"\(.title)\" by @\(.user.login)\n  \(.html_url)"' relevant_pulls.jsonl \
        > "$project-reviews.text"
    jq -r '"<li><a href=\"\(.html_url)\">PR #\(.number)</a>: \"\(.title)\" by @\(.user.login)</li>"' relevant_pulls.jsonl \
        > "$project-reviews.html"
    rm -f pulls.json relevant_pulls.jsonl

    [[ ! -s $project-reviews.text ]] && rm -f "$project-reviews.text" "$project-reviews.html"
done


# Generate the email subject and <title> for the text/html email
subject="Daily triage for: ${projects[*]} [$cloud_init_triager and $ua_triager]"


# Generate the text/plain mail body
{
    printf '# Daily bug triage for: %s\n\n' "${projects[*]}"
    echo "Today's cloud-init triager: $cloud_init_triager"
    echo "Today's UA triager: $ua_triager"

    for project in "${projects[@]}"; do
        printf '\n## %s active bugs (%s days) and New bugs (%s days)\n\n' "$project" $ndays $ndays_new_bugs
        cat "$project-bugs.text"

        if [ -e "$project-reviews.text" ]; then
            printf '\n## %s reviews without an assignee\n\n' "$project"
            cat "$project-reviews.text"
            rm -f "$project-reviews.text"
        fi
    done

    for github_project in "${github_projects[@]}"; do
        if [ -e "$github_project-reviews.text" ]; then
            printf '\n## %s reviews without an assignee\n\n' "$github_project"
            cat "$github_project-reviews.text"
        fi
    done
} > mail-body.text


# Generate the text/html mail body (a valid HTML5 document)
{
    printf '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="UTF-8">\n'
    echo "<title>$subject</title>"
    printf '</head>\n<body>\n'
    echo "<h4>Daily bug triage for: ${projects[*]}</h4>"
    echo "Today's cloud-init triager: $cloud_init_triager"
    echo "Today's UA triager: $ua_triager"

    for project in "${projects[@]}"; do
        sed 's|\(lp: #\)\([0-9][0-9]*\)|lp: <a href="https://pad.lv/\2">#\2</a>|' "$project-bugs.text" > "$project-bugs.html"
        echo "<h5>$project active bugs ($ndays days) and new bugs ($ndays_new_bugs days)</h5>"
        echo "<pre>"
        cat "$project-bugs.html"
        echo "</pre>"

        if [ -e "$project-reviews.html" ]; then
            echo "<h5>$project reviews without an assignee</h5>"
            echo "<ul>"
            cat "$project-reviews.html"
            echo "</ul>"
            rm -f "$project-reviews.html"
        fi
    done

    for github_project in "${github_projects[@]}"; do
        if [ -e "$github_project-reviews.html" ]; then
            echo "<h5>$github_project reviews without an assignee</h5>"
            echo "<ul>"
            cat "$github_project-reviews.html"
            echo "</ul>"
        fi
    done
} > mail-body.html


# Generate the full multipart/alternative email message
{
    recipients="server-table-flip@lists.canonical.com"
    mpboundary="multipart-boundary-$(date --utc '+%s%N')"
    cat <<-EOF
	From: server@jenkins.canonical.com
	To: $recipients
	Subject: $subject
	MIME-Version: 1.0
	Content-Type: multipart/alternative; boundary="$mpboundary"

	--$mpboundary
	Content-type: text/plain; charset="UTF-8"

	EOF
    cat mail-body.text
    cat <<-EOF
	--$mpboundary
	Content-type: text/html; charset="UTF-8"

	EOF
    cat mail-body.html
    echo "--$mpboundary--"
} > mail-smtp


# Send the email.
if [ -z "$TRIAGE_NO_SENDMAIL" ]; then
    /usr/sbin/sendmail -t < mail-smtp
else
    echo "Mail output in mail-smtp"
fi
