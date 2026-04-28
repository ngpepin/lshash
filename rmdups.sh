#!/bin/bash
echo "Finding .dups directories..."
sudo find . -type d -name '.dups' -exec realpath {} \;
echo "Removing .dups directories..."
for i in {5..1}; do
    echo -ne "Removing in $i seconds...\r"
    sleep 1
done
echo -e "Removing now!            \n"
sudo find . -type d -name '.dups' -exec rm -r {} +
echo "Confirming removal of .dups directories..."
sudo find . -type d -name '.dups' -exec realpath {} \;