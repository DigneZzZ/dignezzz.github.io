import React, { useState, useEffect } from 'react';
import { Button } from './../Components';
import figlet from 'figlet';
import { useCallback } from 'react';
import ReactGA from 'react-ga4';
interface AppProps {}

function Home({}: AppProps) {
  const [inputText, setInputText] = useState('');
  const [outputText, setOutputText] = useState('');
  const [font, setFont] = useState('Standard');

  // loop through the options in the fonts directory and add them to an array
  const [fonts, setFonts] = useState([]);
  useEffect(() => {
    // get the fonts list from the json file in the public directory
    fetch('fonts.json')
      .then((res) => res.json())
      .then((data) => {
        console.log(data.fonts);
        setFonts(data.fonts);
      });
  }, []);

  // Return the App component.
  return (
    <div className="mb-8 mt-8">
      <h1 className=" text-green-400 drop-shadow xl:block hidden  shadow-green-400 bg-transparent  text-center font-[Monospace] whitespace-pre text-[10px] overflow-clip">
        {bannerFull}
      </h1>
      <h1 className=" text-green-400 md:block xl:hidden hidden  drop-shadow shadow-green-400 bg-transparent  text-center font-[Monospace] whitespace-pre text-[10px] overflow-clip">
        {bannerMed}
      </h1>
      <h1 className=" text-green-400 md:hidden sm:block drop-shadow shadow-green-400 bg-transparent  text-center font-[Monospace] whitespace-pre text-[0.5rem] overflow-clip">
        {bannerMed}
      </h1>
      <div className="flex flex-col space-y-8 mt-8 mx-4 ">
        <div className="flex">
          <input
            type="text"
            value={inputText}
            onChange={(e) => {
              console.log(e.target.value);
              setInputText(e.target.value);
              // @ts-ignore
              figlet.text(
                e.target.value,
                { font: font },
                function (err: any, data: any) {
                  if (err) {
                    console.log(err);
                    return;
                  }
                  setOutputText(data);
                  console.log(data);
                },
              );
            }}
            className="w-full border border-green-400  outline-none  p-2 rounded-lg bg-transparent text-green-400 shadow  transition-all shadow-green-400 placeholder-green-700"
            placeholder="Enter text here"
          />
        </div>
        <input
          type="range"
          min="0"
          // @ts-ignore
          value={fonts.indexOf(font)}
          onChange={(e) => {
            // @ts-ignore
            setFont(fonts[e.target.value]);
            figlet.text(
              inputText,
              // @ts-ignore
              { font: fonts[e.target.value] },
              function (err: any, data: any) {
                if (err) {
                  console.log(err);
                  return;
                }
                setOutputText(data);
                console.log(data);
              },
            );
          }}
          max={fonts.length - 1}
          className="mt-8 bg-transparent appearance-none border-green-400 border rounded-full shadow shadow-green-400"
        />
        <div className="text-white">
          <p className="p-4 border border-green-400 shadow shadow-green-400 overflow-x-scroll empty:hidden rounded-lg w-full float-left font-[Monospace] whitespace-pre text-[10px] text-green-400">
            {outputText}
          </p>
        </div>
        <div className="flex flex-row justify-evenly">
          <select
            className="outline-none shadow shadow-green-400 text-green-400 p-1 rounded-lg bg-[rgb(10,10,10)] border border-green-400"
            value={font}
            onChange={(e) => {
              setFont(e.target.value);
              // @ts-ignore
              figlet.text(
                inputText,
                {
                  font: e.target.value,
                },
                function (err: any, data: any) {
                  if (err) {
                    console.log(err);
                    return;
                  }
                  setOutputText(data);
                  console.log(data);
                },
              );
            }}
          >
            {fonts.map((font: any, index: number) => (
              <option
                key={index}
                value={font}
                className="text-green-400 border border-green-400 focus:bg-green-400 "
              >
                {font}
              </option>
            ))}
          </select>
          <div className="">
            <Button
              onClick={() => {
                ReactGA.event({
                  category: 'User Action',
                  action: "Clicked on the 'Copy' button",
                  label: 'Copied to clipboard',
                });
                navigator.clipboard.writeText(outputText);
              }}
              className="text-green-400 shadow shadow-green-400 drop-shadow rounded-lg bg-black border border-green-400"
            >
              Copy to Clipboard
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}

// set a ascii art banner for the title
const bannerFull = `
█████████    █████████    █████████  █████ █████    ███████████ ██████████ █████ █████ ███████████      █████████  ██████████ ██████   █████ ██████████ ███████████     █████████   ███████████    ███████    ███████████  
███░░░░░███  ███░░░░░███  ███░░░░░███░░███ ░░███    ░█░░░███░░░█░░███░░░░░█░░███ ░░███ ░█░░░███░░░█     ███░░░░░███░░███░░░░░█░░██████ ░░███ ░░███░░░░░█░░███░░░░░███   ███░░░░░███ ░█░░░███░░░█  ███░░░░░███ ░░███░░░░░███ 
░███    ░███ ░███    ░░░  ███     ░░░  ░███  ░███    ░   ░███  ░  ░███  █ ░  ░░███ ███  ░   ░███  ░     ███     ░░░  ░███  █ ░  ░███░███ ░███  ░███  █ ░  ░███    ░███  ░███    ░███ ░   ░███  ░  ███     ░░███ ░███    ░███ 
░███████████ ░░█████████ ░███          ░███  ░███        ░███     ░██████     ░░█████       ░███       ░███          ░██████    ░███░░███░███  ░██████    ░██████████   ░███████████     ░███    ░███      ░███ ░██████████  
░███░░░░░███  ░░░░░░░░███░███          ░███  ░███        ░███     ░███░░█      ███░███      ░███       ░███    █████ ░███░░█    ░███ ░░██████  ░███░░█    ░███░░░░░███  ░███░░░░░███     ░███    ░███      ░███ ░███░░░░░███ 
░███    ░███  ███    ░███░░███     ███ ░███  ░███        ░███     ░███ ░   █  ███ ░░███     ░███       ░░███  ░░███  ░███ ░   █ ░███  ░░█████  ░███ ░   █ ░███    ░███  ░███    ░███     ░███    ░░███     ███  ░███    ░███ 
█████   █████░░█████████  ░░█████████  █████ █████       █████    ██████████ █████ █████    █████       ░░█████████  ██████████ █████  ░░█████ ██████████ █████   █████ █████   █████    █████    ░░░███████░   █████   █████
░░░░░   ░░░░░  ░░░░░░░░░    ░░░░░░░░░  ░░░░░ ░░░░░       ░░░░░    ░░░░░░░░░░ ░░░░░ ░░░░░    ░░░░░         ░░░░░░░░░  ░░░░░░░░░░ ░░░░░    ░░░░░ ░░░░░░░░░░ ░░░░░   ░░░░░ ░░░░░   ░░░░░    ░░░░░       ░░░░░░░    ░░░░░   ░░░░░ 
                                                                                                                                                                                                                                                                                                                                                                                                                                                    
`;

const bannerMed = `
█████████    █████████    █████████  █████ █████    ███████████ ██████████ █████ █████ ███████████   
███░░░░░███  ███░░░░░███  ███░░░░░███░░███ ░░███    ░█░░░███░░░█░░███░░░░░█░░███ ░░███ ░█░░░███░░░█  
░███    ░███ ░███    ░░░  ███     ░░░  ░███  ░███    ░   ░███  ░  ░███  █ ░  ░░███ ███  ░   ░███  ░  
░███████████ ░░█████████ ░███          ░███  ░███        ░███     ░██████     ░░█████       ░███     
░███░░░░░███  ░░░░░░░░███░███          ░███  ░███        ░███     ░███░░█      ███░███      ░███     
░███    ░███  ███    ░███░░███     ███ ░███  ░███        ░███     ░███ ░   █  ███ ░░███     ░███     
█████   █████░░█████████  ░░█████████  █████ █████       █████    ██████████ █████ █████    █████    
░░░░░   ░░░░░  ░░░░░░░░░    ░░░░░░░░░  ░░░░░ ░░░░░       ░░░░░    ░░░░░░░░░░ ░░░░░ ░░░░░    ░░░░░    
                                                                                                     
█████████  ██████████ ██████   █████ ██████████ ███████████     █████████   ███████████    ███████    ███████████  
███░░░░░███░░███░░░░░█░░██████ ░░███ ░░███░░░░░█░░███░░░░░███   ███░░░░░███ ░█░░░███░░░█  ███░░░░░███ ░░███░░░░░███ 
███     ░░░  ░███  █ ░  ░███░███ ░███  ░███  █ ░  ░███    ░███  ░███    ░███ ░   ░███  ░  ███     ░░███ ░███    ░███ 
░███          ░██████    ░███░░███░███  ░██████    ░██████████   ░███████████     ░███    ░███      ░███ ░██████████  
░███    █████ ░███░░█    ░███ ░░██████  ░███░░█    ░███░░░░░███  ░███░░░░░███     ░███    ░███      ░███ ░███░░░░░███ 
░░███  ░░███  ░███ ░   █ ░███  ░░█████  ░███ ░   █ ░███    ░███  ░███    ░███     ░███    ░░███     ███  ░███    ░███ 
░░█████████  ██████████ █████  ░░█████ ██████████ █████   █████ █████   █████    █████    ░░░███████░   █████   █████
  ░░░░░░░░░  ░░░░░░░░░░ ░░░░░    ░░░░░ ░░░░░░░░░░ ░░░░░   ░░░░░ ░░░░░   ░░░░░    ░░░░░       ░░░░░░░    ░░░░░   ░░░░░

`;

export default Home;
