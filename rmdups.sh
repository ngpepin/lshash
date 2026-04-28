#!/bin/bash
echo "Finding .dups directories..."
sudo find . -type d -name '.dups' -exec realpath {} \;
echo "Removing .dups directories..."
sudo find . -type d -name '.dups' -exec rm -r {} +
echo "Confirming removal of .dups directories..."
sudo find . -type d -name '.dups' -exec realpath {} \;
if [ $? -eq 0 ]; then
	echo "Error: .dups directories still exist."
else
	echo "All .dups directories have been removed successfully."
fi