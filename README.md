# my Unix scripts
My mac scripts, which are convenient to call using spotlight search.

## Usage

1. Clone this repository, and add the directory to your PATH environment variable.

For zsh:
```{zsh}
git clone https://github.com/Sigurd-git/Unix-scripts.git
cd Unix-scripts
echo "PATH=$PWD:$PATH">> ~/.zshrc
source ~/.zshrc
```
For bash:
```{bash}
git clone https://github.com/Sigurd-git/Unix-scripts.git
cd Unix-scripts
echo "PATH=$PWD:$PATH">> ~/.bashrc
source ~/.bashrc
```

2. Change the file mode to executable.
```
chmod 755 *
```

2. Create a file named user_password.txt in the same directory as the script file, and write your bluehive account in the first line, like:

```
username
password
```

3. Set the ssh config file, like:

```
Host Bluehive
	Hostname bluehive.circ.rochester.edu
	User username

Host Bluehive_compute_dmi
	Hostname bhc0208
	User username
	ProxyJump Bluehive
    StrictHostKeyChecking no

Host Bluehive_compute_doppelbock
	Hostname bhg0061
	User username
	ProxyJump Bluehive
	StrictHostKeyChecking no
```



