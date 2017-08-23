#!/bin/bash
# Program to build and sign debian packages, and upload those to a public reprepro repository.
# Copyright (c) 2015 Santiago Bassett <santiago.bassett@gmail.com>

# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software Foundation,
# Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

set -o nounset
set -o errexit

#
# CONFIGURATION VARIABLES
#

packages=(ossec-hids ossec-hids-agent)

# For Debian use: sid, jessie or wheezy (hardcoded in update_changelog function)
build_codenames=(trusty)
codenames_ubuntu=(trusty)
codenames_debian=(sid jessie wheezy)

# architectures=(amd64 i386) only options available
architectures=(amd64)

# GPG key
signing_key=''
signing_pass=''

# Setting up logfile
WORK_HOME="$(cd "$(dirname "$0")" ; pwd -P)"
WORK_HOME="/tmp/ossec"

logfile="${WORK_HOME}/ossec_packages.log"

#
# Function to write to LOG_FILE
#
write_log() {
  if [ ! -e "$logfile" ] ; then
    touch "$logfile"
  fi
  while read -r text; do
      local logtime
      logtime="$(date "+%Y-%m-%d %H:%M:%S")"
      echo "${logtime}: ${text}" | tee -a "$logfile";
  done
}

#
# Check if element is in an array
# Arguments: element array
#
contains_element() {
  local e
  for e in "${@:2}"; do [[ "$e" == "$1" ]] && return 0; done
  return 1
}


#
# Show help function
#
show_help() {
  echo "
  This tool can be used to generate OSSEC packages for Ubuntu and Debian.

  CONFIGURATION: The script is currently configured with the following variables:
    * Packages: ${packages[*]}.
    * Distributions: ${build_codenames[*]}.
    * Architectures: ${architectures[*]}.
    * Signing key: ${signing_key}.

  USAGE: Command line arguments available:
    -h | --help     Displays this help.
    -u | --update   Updates chroot environments.
    -d | --download Downloads source file and prepares source directories.
    -b | --build    Builds deb packages.
    -s | --sync     Synchronizes with the apt-get repository.
  "
}


#
# Reads latest package version from changelog file
# Argument: changelog_file
#
read_package_version() {
  if [ ! -e "$1" ] ; then
    echo "Error: Changelog file $1 does not exist" | write_log
    exit 1
  fi

  local regex="^ossec-hids[A-Za-z-]* \([0-9]+.*[0-9]*.*[0-9]*-([0-9]+)[A-Za-z]*\)"
  while read -r line; do
    if [[ "$line" =~ $regex ]]; then
      package_version="${BASH_REMATCH[1]}"
      break
    fi
  done < "$1"

  local check_regex='^[0-9]+$'
  if ! [[ ${package_version} =~ ${check_regex} ]]; then
    echo "Error: Package version could not be read from $1" | write_log
    exit 1
  fi
}


#
# Updates changelog file with new codename, date and debdist.
# Arguments: changelog_file codename
#
update_changelog() {
  local changelog_file="$1"
  local package="$2"
  local version="$3"

  local debian_revision
  debian_revision="$(dpkg-parsechangelog --show-field Version -l "$changelog_file" | sed 's/.*-//g')"

  local debdist
  local check_codenames=("${codenames_debian[@]}" "${codenames_ubuntu[@]}")

  local changelog_file_tmp="${changelog_file}.tmp"

  if [ ! -e "$1" ] ; then
    echo "Error: Changelog file $1 does not exist" | write_log
    exit 1
  fi

  # Modifying file
  local changelogtime
  changelogtime="$(date -R)"

  local last_date_changed=0

  local regex1="^(ossec-hids[A-Za-z-]* \([0-9]+.*[0-9]*.*[0-9]*-[0-9]+)[A-Za-z]*\)"
  local regex2="( -- [[:alnum:]]*[^>]*>  )[[:alnum:]]*,"

  if [ -f "$changelog_file_tmp" ]; then
    rm -f "$changelog_file_tmp"
  fi

  touch "$changelog_file_tmp"

  IFS='' #To preserve line leading whitespaces

  while read -r line; do
    if [[ "$line" =~ $regex1 ]]; then
      line="${package} (${version}-${debian_revision})"

      for codename in "${build_codenames[@]}"; do
        if ! contains_element "$codename" "${check_codenames[@]}" ; then
          echo "Error: Codename $codename not contained in codenames for Debian or Ubuntu" | write_log
          exit 1
        fi

        # For Debian
        if [ "$codename" = "sid" ]; then
          debdist="unstable"
        elif [ "$codename" = "jessie" ]; then
          debdist="testing"
        elif [ "$codename" = "wheezy" ]; then
          debdist="stable"
        else
          debdist="$codename"
        fi

        line="${line} ${debdist}"
      done

      line="${line}; urgency=low"
    fi

    if [[ "$line" =~ $regex2 ]] && [ $last_date_changed -eq 0 ]; then
      line="${BASH_REMATCH[1]}$changelogtime"
      last_date_changed=1
    fi

    echo "$line" >> "$changelog_file_tmp"
  done < "$changelog_file"

  unset IFS

  cat "$changelog_file_tmp"

  mv "$changelog_file_tmp" "$changelog_file"
}


#
# Update chroot environments
#
update_chroots() {
  local basetgz aptcache verb

  for codename in "${build_codenames[@]}"; do
    for arch in "${architectures[@]}"; do
      basetgz="$(pbuilder_base_tgz "$codename" "$arch")"
      aptcache="$(pbuilder_apt_cache "$codename" "$arch")"

      local args
      args=($(pbuilder_args "$codename" "$arch"))

      if [[ -f "$basetgz" ]]; then
        verb="update"
      else
        verb="create"
      fi

      sudo mkdir -p "$(dirname "$basetgz")"
      sudo mkdir -p "$aptcache"

      echo "Sync chroot environment (${verb}): ${codename}-${arch}" | write_log
      if sudo pbuilder "$verb" "${args[@]}"; then
        echo "Successfully updated chroot environment: ${codename}-${arch}" | write_log
      else
        echo "Error: Problem detected updating chroot environment: ${codename}-${arch}" | write_log
      fi
    done
  done
}

git_source() {
  local repo ossec_version

  repo="$1"
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"

  ossec_version="$(git -C "$repo" describe "$(git -C "$repo" rev-list --tags --max-count=1)")"
  ossec_commits="$(git -C "$repo" rev-list "${ossec_version}..${branch}" --count)"

  package_version="${ossec_version}+${ossec_commits}"

  for package in "${packages[@]}"; do
    rm -rf "${WORK_HOME}/${package}/${package}-${package_version}"

    mkdir -p "${WORK_HOME}/${package}/${package}-${package_version}"
    git -C "$repo" archive --format tar "$branch" | gzip > "${WORK_HOME}/${package}/${package}_${package_version}.orig.tar.gz"
    tar -xf "${WORK_HOME}/${package}/${package}_${package_version}.orig.tar.gz" -C "${WORK_HOME}/${package}/${package}-${package_version}"
    cp -pr "${WORK_HOME}/${package}/${package}-${package_version}/contrib/debian-packages/${package}/debian" "${WORK_HOME}/${package}/${package}-${package_version}/debian"

    echo "$package_version" > "${WORK_HOME}/${package}/${package}-${package_version}/debian/VERSION"
  done
}


#
# Downloads packages and prepare source directories.
# This is needed before building the packages.
#
download_source() {
  ossec_version="$1"

  origin="https://github.com/ossec/ossec-hids"
  source_file="ossec-hids-${ossec_version}.tar.gz"

  # TODO - Debian files

  # Checking that Debian files exist for this version
  for package in ${packages[*]}; do
    if [ ! -d "${debian_files_path}/${package}/debian" ]; then
      echo "Error: Couldn't find debian files directory for $package, version ${ossec_version}" | write_log
      exit 1
    fi
  done

  # Downloading file
  if wget -O "$WORK_HOME/${source_file}" -U ossec "${origin}/archive/${ossec_version}.tar.gz" ; then
    echo "Successfully downloaded source file ${source_file} from ossec.net" | write_log
  else
    echo "Error: File ${source_file} was could not be downloaded" | write_log
    exit 1
  fi

  # Uncompressing files
  tmp_directory="$(echo ${source_file} | sed -e 's/.tar.gz$//')"
  if [ -d "${WORK_HOME}/${tmp_directory}" ]; then
    echo " + Deleting previous directory ${WORK_HOME}/${tmp_directory}" | write_log
    sudo rm -rf "${WORK_HOME}/${tmp_directory}"
  fi

  tar -xvzf "${WORK_HOME}/${source_file}"
  if [ ! -d "${WORK_HOME}/${tmp_directory}" ]; then
    echo "Error: Couldn't find uncompressed directory, named ${tmp_directory}" | write_log
    exit 1
  fi

  # Organizing directories structure
  for package in "${packages[@]}"; do
    if [ -d "${WORK_HOME}/${package}" ]; then
      echo " + Deleting previous source directory ${WORK_HOME}/$package" | write_log
      sudo rm -rf "${WORK_HOME}/$package"
    fi

    mkdir "$WORK_HOME/$package"
    cp -pr "$WORK_HOME/${tmp_directory}" "$WORK_HOME/$package/$package-${ossec_version}"
    cp -p "$WORK_HOME/${source_file}" "$WORK_HOME/$package/${package}_${ossec_version}.orig.tar.gz"
    cp -pr "${debian_files_path}/${ossec_version}/$package/debian" "${WORK_HOME}/${package}/${package}-${ossec_version}/debian"

    # TODO- Add VERSION
  done

  rm -rf "${WORK_HOME:?}/${tmp_directory}"

  echo "The packages directories for ${packages[*]} version ${ossec_version} have been successfully prepared." | write_log
}

pbuilder_base_tgz() {
  local codename arch
  codename="$1"
  arch="$2"

  echo "/var/cache/pbuilder/${codename}-${arch}/base.tgz"
}

pbuilder_apt_cache() {
  local codename arch
  codename="$1"
  arch="$2"

  echo "/var/cache/pbuilder/${codename}-${arch}/aptcache"
}

pbuilder_args() {
  local codename arch basetgz aptcache
  codename="$1"
  arch="$2"

  basetgz="$(pbuilder_base_tgz "$codename" "$arch")"
  aptcache="$(pbuilder_apt_cache "$codename" "$arch")"

  echo "--basetgz $basetgz  --aptcache ${aptcache} --distribution ${codename} --architecture ${arch}"
}


#
# Build packages
#
build_packages() {
  local ossec_version ossec_version_file

  for package in "${packages[@]}"; do
    for codename in "${build_codenames[@]}"; do
      for arch in "${architectures[@]}"; do
        for src in "${WORK_HOME}/${package}"/*; do

          ossec_version_file="${src}/debian/VERSION"
          if [[ ! -f "$ossec_version_file" ]]; then
            # Not a source dir
            continue
          fi

          ossec_version="$(cat "$ossec_version_file")"

          echo "Building Debian package ${package} ${codename}-${arch}" | write_log

          local source_path="${WORK_HOME}/${package}/${package}-${ossec_version}"
          local changelog_file="${source_path}/debian/changelog"

          if [ ! -f "${changelog_file}" ] ; then
            echo "Error: Couldn't find changelog file for ${package}-${ossec_version}" | write_log
            exit 1
          fi

          # Updating changelog file with new codename, date and debdist.
          if update_changelog "$changelog_file" "$package" "$ossec_version"; then
            echo " + Changelog file ${changelog_file} updated for $package ${codename}-${arch}" | write_log
          else
            echo "Error: Changelog file ${changelog_file} for $package ${codename}-${arch} could not be updated" | write_log
            exit 1
          fi

          # Setting up global variable package_version, used for deb_file and changes_file
          read_package_version "${changelog_file}"
          local deb_file="${package}_${ossec_version}-${package_version}_${arch}.deb"
          local changes_file="${package}_${ossec_version}-${package_version}_${arch}.changes"
          local dsc_file="${package}_${ossec_version}-${package_version}.dsc"
          local results_dir="/var/cache/pbuilder/${codename}-${arch}/result/${package}"

          # Creating results directory if it does not exist
          if [ ! -d "${results_dir}" ]; then
            sudo mkdir -p "${results_dir}"
          fi

          # Building the package
          cd "${source_path}"

          local args
          args=($(pbuilder_args "$codename" "$arch"))

          if sudo /usr/bin/pdebuild --use-pdebuild-internal --architecture "${arch}" --buildresult "${results_dir}" -- "${args[@]}" --override-config; then
            echo " + Successfully built Debian package ${package} ${codename}-${arch}" | write_log
          else
            echo "Error: Could not build package $package ${codename}-${arch}" | write_log
            exit 1
          fi

          # Checking that resulting debian package exists
          if [ ! -f "${results_dir}/${deb_file}" ] ; then
            echo "Error: Could not find ${results_dir}/${deb_file}" | write_log
            exit 1
          fi

          # Checking that package has at least 50 files to confirm it has been built correctly
          local files
          files="$(sudo /usr/bin/dpkg --contents "${results_dir}/${deb_file}" | wc -l)"

          if [ "${files}" -lt "50" ]; then
            echo "Error: Package ${package} ${codename}-${arch} contains only ${files} files" | write_log
            echo "Error: Check that the Debian package has been built correctly" | write_log
            exit 1
          else
            echo " + Package ${results_dir}/${deb_file} ${codename}-${arch} contains ${files} files" | write_log
          fi

          # Signing Debian package
          if [ ! -f "${results_dir}/${changes_file}" ] || [ ! -f "${results_dir}/${dsc_file}" ] ; then
            echo "Error: Could not find dsc and changes file in ${results_dir}" | write_log
            exit 1
          fi

          if [[ -n "$signing_key" ]] && [[ -n "$signing_pass" ]]; then
            sudo /usr/bin/expect -c "
            spawn sudo debsign --re-sign -k${signing_key} ${results_dir}/${changes_file}
            expect -re \".*Enter passphrase:.*\"
            send \"${signing_pass}\r\"
            expect -re \".*Enter passphrase:.*\"
            send \"${signing_pass}\r\"
            expect -re \".*Successfully signed dsc and changes files.*\"
            "

            if [ $? -eq 0 ] ; then
              echo " + Successfully signed Debian package ${changes_file} ${codename}-${arch}" | write_log
            else
              echo "Error: Could not sign Debian package ${changes_file} ${codename}-${arch}" | write_log
              exit 1
            fi

            # Verifying signed changes and dsc files
            if sudo gpg --verify "${results_dir}/${dsc_file}" && sudo gpg --verify "${results_dir}/${changes_file}" ; then
              echo " + Successfully verified GPG signature for files ${dsc_file} and ${changes_file}" | write_log
            else
              echo "Error: Could not verify GPG signature for ${dsc_file} and ${changes_file}" | write_log
              exit 1
            fi
          fi

          echo "Successfully built and signed Debian package ${package} ${codename}-${arch}" | write_log
        done
      done
    done
  done
}

# Synchronizes with the external repository, uploading new packages and ubstituting old ones.
sync_repository() {
for package in "${packages[@]}"; do
  for codename in "${build_codenames[@]}"; do
    for arch in "${architectures[@]}"; do
      # Reading package version from changelog file
      local source_path="$WORK_HOME/${package}/${package}-${ossec_version}"
      local changelog_file="${source_path}/debian/changelog"
      if [ ! -f "${changelog_file}" ] ; then
        echo "Error: Couldn't find ${changelog_file} for package ${package} ${codename}-${arch}" | write_log
        exit 1
      fi

      # Setting up global variable package_version, used for deb_file and changes_file.
      read_package_version "${changelog_file}"
      local deb_file="${package}_${ossec_version}-${package_version}${codename}_${arch}.deb"
      local changes_file="${package}_${ossec_version}-${package_version}${codename}_${arch}.changes"
      local results_dir="/var/cache/pbuilder/${codename}-${arch}/result/${package}"
      if [ ! -f "${results_dir}/${deb_file}" ] || [ ! -f "${results_dir}/${changes_file}" ] ; then
        echo "Error: Coudn't find ${deb_file} or ${changes_file}" | write_log
        exit 1
      fi

      # Uploading package to repository
      cd "${results_dir}"

      echo "Uploading package ${changes_file} for ${codename} to OSSEC repository" | write_log

      if sudo /usr/bin/dupload --nomail -f --to ossec-repository "${changes_file}"; then
        echo " + Successfully uploaded package ${changes_file} for ${codename} to OSSEC repository" | write_log
      else
        echo "Error: Could not upload package ${changes_file} for ${codename} to the repository" | write_log
        exit 1
      fi

      # Checking if it is an Ubuntu package
      if contains_element "$codename" "${codenames_ubuntu[@]}"; then
        local is_ubuntu=1
      else
        local is_ubuntu=0
      fi

      # Moving package to the right directory at the OSSEC apt repository server
      echo " + Adding package /opt/incoming/${deb_file} to server repository for ${codename} distribution" | write_log

      if [ $is_ubuntu -eq 1 ]; then
        remove_package="cd /var/www/repos/apt/ubuntu; reprepro -A ${arch} remove ${codename} ${package}"
        include_package="cd /var/www/repos/apt/ubuntu; reprepro includedeb ${codename} /opt/incoming/${deb_file}"
      else
        remove_package="cd /var/www/repos/apt/debian; reprepro -A ${arch} remove ${codename} ${package}"
        include_package="cd /var/www/repos/apt/debian; reprepro includedeb ${codename} /opt/incoming/${deb_file}"
      fi

      /usr/bin/expect -c "
        spawn sudo ssh root@ossec-repository \"${remove_package}\"
        expect -re \"Not removed as not found.*\" { exit 1 }
        expect -re \".*enter passphrase:.*\" { send \"${signing_pass}\r\" }
        expect -re \".*enter passphrase:.*\" { send \"${signing_pass}\r\" }
        expect -re \".*deleting.*\"
      "

      /usr/bin/expect -c "
        spawn sudo ssh root@ossec-repository \"${include_package}\"
        expect -re \"Skipping inclusion.*\" { exit 1 }
        expect -re \".*enter passphrase:.*\"
        send \"${signing_pass}\r\"
        expect -re \".*enter passphrase:.*\"
        send \"${signing_pass}\r\"
        expect -re \".*Exporting.*\"
      "
      echo "Successfully added package ${deb_file} to server repository for ${codename} distribution" | write_log
    done
  done
done
}


# If there are no arguments, display help
if [ $# -eq 0 ]; then
  show_help
  exit 0
fi

# Reading command line arguments
while [[ "$#" -gt 0 ]]; do
  key="$1"
  shift

  case $key in
    -h|--help)
      show_help
      exit 0
      ;;
    -u|--update)
      update_chroots
      ;;
    -d|--download)
      download_source "$1"
      shift
      ;;
    -g|--git)
      git_source "$1"
      shift
      ;;
    -b|--build)
      build_packages
      ;;
    -s|--sync)
      sync_repository
      ;;
    *)
      echo "Unknown command line argument."
      show_help
      exit 0
      ;;
  esac
done

# vim: tabstop=2 expandtab shiftwidth=2 softtabstop=2
