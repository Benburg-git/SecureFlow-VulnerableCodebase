import subprocess

def run_user_command(user_input):
    subprocess.run(user_input, shell=True)