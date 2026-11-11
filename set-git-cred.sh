#!/bin/bash
#
##################################################################################################################
# Adapted for GitHub by bojanstrkovski-21
##################################################################################################################
##################################################################################################################
#
#   DO NOT JUST RUN THIS. EXAMINE AND JUDGE. RUN AT YOUR OWN RISK.
#
##################################################################################################################

project=butterview-arch
echo "-----------------------------------------------------------------------------"
echo "this is project https://github.com/bojanstrkovski-21/$project"
echo "-----------------------------------------------------------------------------"

git config --global pull.rebase false
git config --global user.name "bojanstrkovski-21"
git config --global user.email "bojanstrkovski.21@gmail.com"
git config --global push.default simple
git remote set-url origin "https://github.com/bojanstrkovski-21/$project.git" || \
  git remote add origin "https://github.com/bojanstrkovski-21/$project.git"

echo "Everything set"
echo "################################################################"
echo "###################    T H E   E N D      ######################"
echo "################################################################"
